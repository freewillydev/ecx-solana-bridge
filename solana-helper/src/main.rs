use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use solana_hash::Hash;
use solana_keypair::read_keypair_file;
use solana_message::Message;
use solana_pubkey::Pubkey;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::{
    address::get_associated_token_address_with_program_id,
    instruction::create_associated_token_account_idempotent,
};
use std::{
    fs,
    io::{self, Read},
    path::Path,
    str::FromStr,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    deployment_id: String,
    mint: String,
    custody_owner: String,
    signer_path: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Verb {
    Deposit,
    Payout,
    PayoutPreview,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    protocol: u8,
    verb: Verb,
    owner: String,
    recipient: String,
    amount: String,
    blockhash: String,
    order_id: String,
    create_ata: bool,
}
#[derive(Serialize)]
struct Reply {
    protocol: u8,
    transaction: String,
    message: String,
    signature: Option<String>,
    source_ata: String,
    destination_ata: String,
    memo: String,
}
fn key(s: &str) -> Result<Pubkey, &'static str> {
    if s.len() > 44 {
        return Err("invalid_public_key");
    }
    Pubkey::from_str(s).map_err(|_| "invalid_public_key")
}
fn raw_amount(s: &str) -> Result<u64, &'static str> {
    if s.is_empty() || s.len() > 20 || !s.bytes().all(|c| c.is_ascii_digit()) || s.starts_with('0')
    {
        return Err("invalid_amount");
    }
    s.parse::<u64>().map_err(|_| "invalid_amount")
}
fn identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn prepare(c: &Config, r: &Request) -> Result<Reply, &'static str> {
    if r.protocol != 1 || !identifier(&c.deployment_id) || !identifier(&r.order_id) {
        return Err("invalid_protocol_or_identifier");
    }
    let amount = raw_amount(&r.amount)?;
    let mint = key(&c.mint)?;
    let custody = key(&c.custody_owner)?;
    let owner = key(&r.owner)?;
    let recipient = key(&r.recipient)?;
    if owner == recipient || !owner.is_on_curve() || !recipient.is_on_curve() {
        return Err("unsupported_owner");
    }
    let payout = matches!(r.verb, Verb::Payout | Verb::PayoutPreview);
    if (payout && owner != custody) || (!payout && recipient != custody) {
        return Err("wrong_custody_owner");
    }
    if !payout && r.create_ata {
        return Err("deposit_requires_existing_custody_ata");
    }
    if payout && !r.create_ata {
        return Err("payout_requires_idempotent_ata_binding");
    }
    let blockhash = Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    let program = spl_token_interface::id();
    let source = get_associated_token_address_with_program_id(&owner, &mint, &program);
    let dest = get_associated_token_address_with_program_id(&recipient, &mint, &program);
    let kind = if payout { "payout" } else { "deposit" };
    let memo = format!("ecx-bridge:v1:{}:{}:{}", c.deployment_id, kind, r.order_id);
    let mut instructions = Vec::new();
    if r.create_ata {
        instructions.push(create_associated_token_account_idempotent(
            &owner, &recipient, &mint, &program,
        ));
    }
    instructions.push(
        spl_token_interface::instruction::transfer_checked(
            &program,
            &source,
            &mint,
            &dest,
            &owner,
            &[],
            amount,
            8,
        )
        .map_err(|_| "invalid_transfer")?,
    );
    instructions.push(spl_memo_interface::instruction::build_memo(
        &spl_memo_interface::v3::id(),
        memo.as_bytes(),
        &[&owner],
    ));
    let message = Message::new_with_blockhash(&instructions, Some(&owner), &blockhash);
    let message_bytes = bincode::serialize(&message).map_err(|_| "serialization_failed")?;
    let mut transaction = Transaction::new_unsigned(message);
    // Admission can inspect the exact payout message without opening a signer.
    // Keep this separate from the economic direction: previews still include
    // the same custody binding, idempotent ATA instruction and payout memo.
    let signature = if matches!(r.verb, Verb::Payout) {
        let path = c.signer_path.as_ref().ok_or("signer_not_configured")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let m = fs::metadata(path).map_err(|_| "signer_unavailable")?;
            if !m.is_file() || m.permissions().mode() & 0o077 != 0 {
                return Err("unsafe_signer_permissions");
            }
        }
        let signer = read_keypair_file(path).map_err(|_| "signer_unavailable")?;
        if signer.pubkey() != custody {
            return Err("signer_mismatch");
        }
        transaction
            .try_sign(&[signer], blockhash)
            .map_err(|_| "signing_failed")?;
        transaction
            .verify()
            .map_err(|_| "signature_verification_failed")?;
        Some(transaction.signatures[0].to_string())
    } else {
        None
    };
    let bytes = bincode::serialize(&transaction).map_err(|_| "serialization_failed")?;
    if bytes.len() > 1232 {
        return Err("transaction_too_large");
    }
    Ok(Reply {
        protocol: 1,
        transaction: STANDARD.encode(bytes),
        message: STANDARD.encode(message_bytes),
        signature,
        source_ata: source.to_string(),
        destination_ata: dest.to_string(),
        memo,
    })
}
fn run() -> Result<Reply, &'static str> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || args[1] != "--config" {
        return Err("usage_requires_fixed_config");
    }
    let path = Path::new(&args[2]);
    let config_bytes = fs::read(path).map_err(|_| "config_unavailable")?;
    if config_bytes.len() > 4096 {
        return Err("config_too_large");
    }
    let config: Config = serde_json::from_slice(&config_bytes).map_err(|_| "invalid_config")?;
    let mut input = Vec::new();
    io::stdin()
        .take(8193)
        .read_to_end(&mut input)
        .map_err(|_| "input_failed")?;
    if input.len() > 8192 {
        return Err("input_too_large");
    }
    let request: Request = serde_json::from_slice(&input).map_err(|_| "invalid_request")?;
    prepare(&config, &request)
}
fn main() {
    match run() {
        Ok(reply) => println!(
            "{}",
            serde_json::to_string(&reply).expect("serializable reply")
        ),
        Err(code) => {
            eprintln!("{{\"error\":\"{code}\"}}");
            std::process::exit(1);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_integer_boundaries() {
        assert_eq!(raw_amount("3"), Ok(3));
        assert_eq!(raw_amount("18446744073709551615"), Ok(u64::MAX));
        for invalid in [
            "0",
            "00",
            "03",
            "-1",
            "+3",
            "3.0",
            "3e0",
            "18446744073709551616",
        ] {
            assert!(raw_amount(invalid).is_err(), "{invalid}");
        }
    }
    #[test]
    fn unknown_request_fields_rejected() {
        assert!(
            serde_json::from_str::<Request>(r#"{"protocol":1,"verb":"arbitrary_sign"}"#).is_err()
        );
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;
    use solana_keypair::{write_keypair_file, Keypair};
    fn inputs() -> (Config, Request) {
        // Public deterministic fixture keys. Never use these on any network.
        let source = Keypair::new_from_array([1; 32]).pubkey();
        let target = Keypair::new_from_array([2; 32]).pubkey();
        let mint = Keypair::new_from_array([3; 32]).pubkey();
        (
            Config {
                deployment_id: "codec-fixture".into(),
                mint: mint.to_string(),
                custody_owner: target.to_string(),
                signer_path: None,
            },
            Request {
                protocol: 1,
                verb: Verb::Deposit,
                owner: source.to_string(),
                recipient: target.to_string(),
                amount: "3".into(),
                blockhash: Hash::new_from_array([4; 32]).to_string(),
                order_id: "order-1".into(),
                create_ata: false,
            },
        )
    }
    #[test]
    fn unsigned_wire_fidelity() {
        let (c, r) = inputs();
        let out = prepare(&c, &r).unwrap();
        let tx: Transaction =
            bincode::deserialize(&STANDARD.decode(&out.transaction).unwrap()).unwrap();
        assert_eq!(tx.message.instructions.len(), 2);
        assert_eq!(
            tx.message.instructions[0].data,
            vec![12, 3, 0, 0, 0, 0, 0, 0, 0, 8]
        );
        assert!(tx.signatures[0].as_ref().iter().all(|b| *b == 0));
        assert_eq!(tx.message.instructions[1].accounts, vec![0]);
        if let Ok(dest) = std::env::var("ECX_FIXTURE_DIR") {
            fs::create_dir_all(&dest).unwrap();
            let fixture = serde_json::json!({"reply":out,"owner":r.owner,"recipient":r.recipient,"mint":c.mint,"blockhash":r.blockhash,"amount":r.amount,"createAta":false,"signed":false});
            fs::write(
                Path::new(&dest).join("unsigned-three-units.json"),
                serde_json::to_vec_pretty(&fixture).unwrap(),
            )
            .unwrap();
        }
    }
    #[test]
    fn signed_payout_and_idempotent_ata_fidelity() {
        let (mut c, mut r) = inputs();
        r.verb = Verb::Payout;
        r.create_ata = true;
        c.custody_owner = r.owner.clone();
        let keyfile = std::env::temp_dir().join(format!("ecx-fixture-{}.json", std::process::id()));
        write_keypair_file(&Keypair::new_from_array([1; 32]), &keyfile).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&keyfile, fs::Permissions::from_mode(0o600)).unwrap();
        }
        c.signer_path = Some(keyfile.to_string_lossy().into_owned());
        let out = prepare(&c, &r).unwrap();
        fs::remove_file(keyfile).unwrap();
        r.verb = Verb::PayoutPreview;
        // The configured signer no longer exists. A preview must not read it.
        let preview = prepare(&c, &r).unwrap();
        let unsigned: Transaction =
            bincode::deserialize(&STANDARD.decode(&preview.transaction).unwrap()).unwrap();
        assert_eq!(preview.message, out.message);
        assert_eq!(preview.source_ata, out.source_ata);
        assert_eq!(preview.destination_ata, out.destination_ata);
        assert_eq!(preview.signature, None);
        assert!(unsigned.signatures[0].as_ref().iter().all(|b| *b == 0));
        let tx: Transaction =
            bincode::deserialize(&STANDARD.decode(&out.transaction).unwrap()).unwrap();
        tx.verify().unwrap();
        assert_eq!(tx.message.instructions.len(), 3);
        assert_eq!(tx.message.instructions[0].data, vec![1]);
        assert_eq!(
            tx.message.instructions[1].data,
            vec![12, 3, 0, 0, 0, 0, 0, 0, 0, 8]
        );
        assert_eq!(out.signature, Some(tx.signatures[0].to_string()));
        if let Ok(dest) = std::env::var("ECX_FIXTURE_DIR") {
            fs::create_dir_all(&dest).unwrap();
            let fixture = serde_json::json!({"reply":out,"owner":r.owner,"recipient":r.recipient,"mint":c.mint,"blockhash":r.blockhash,"amount":r.amount,"createAta":true,"signed":true});
            fs::write(
                Path::new(&dest).join("signed-three-units.json"),
                serde_json::to_vec_pretty(&fixture).unwrap(),
            )
            .unwrap();
        }
    }
    #[test]
    fn wrong_custody_and_unknown_fields_refused() {
        let (mut c, r) = inputs();
        c.custody_owner = r.owner.clone();
        assert!(prepare(&c, &r).is_err());
        let request = serde_json::json!({"protocol":1,"verb":"deposit","owner":r.owner,"recipient":r.recipient,"amount":"3","blockhash":r.blockhash,"order_id":"order-1","create_ata":false,"instructions":[]});
        assert!(serde_json::from_value::<Request>(request).is_err());
    }
    #[test]
    fn preview_rejects_wrong_custody_off_curve_and_unknown_fields() {
        let (mut c, mut r) = inputs();
        r.verb = Verb::PayoutPreview;
        r.create_ata = true;
        assert_eq!(prepare(&c, &r).err(), Some("wrong_custody_owner"));
        c.custody_owner = r.owner.clone();
        let ata = get_associated_token_address_with_program_id(
            &key(&r.recipient).unwrap(),
            &key(&c.mint).unwrap(),
            &spl_token_interface::id(),
        );
        r.recipient = ata.to_string();
        assert_eq!(prepare(&c, &r).err(), Some("unsupported_owner"));
        let request = serde_json::json!({"protocol":1,"verb":"payout_preview","owner":r.owner,"recipient":r.recipient,"amount":"3","blockhash":r.blockhash,"order_id":"order-1","create_ata":true,"sign":true});
        assert!(serde_json::from_value::<Request>(request).is_err());
    }
    #[test]
    fn unsigned_quote_fixture_never_needs_a_signer() {
        let (mut c, mut r) = inputs();
        c.signer_path = Some("/nonexistent-quote-signer".into());
        r.order_id = "quote-check".into();
        let deposit = prepare(&c, &r).unwrap();
        let wallet = r.owner.clone();
        r.verb = Verb::PayoutPreview;
        r.owner = c.custody_owner.clone();
        r.recipient = wallet.clone();
        r.create_ata = true;
        let payout = prepare(&c, &r).unwrap();
        assert_eq!(deposit.source_ata, payout.destination_ata);
        assert_eq!(deposit.destination_ata, payout.source_ata);
        assert_eq!(deposit.signature, None);
        assert_eq!(payout.signature, None);
        if let Ok(dest) = std::env::var("ECX_FIXTURE_DIR") {
            fs::create_dir_all(&dest).unwrap();
            let fixture = serde_json::json!({"scope":"offline official-SDK codec fixture; never funded or sent", "deploymentId":c.deployment_id,"mint":c.mint,"custodyOwner":c.custody_owner,"wallet":wallet,"blockhash":r.blockhash,"deposit":deposit,"payout":payout});
            fs::write(
                Path::new(&dest).join("admission-unsigned.json"),
                serde_json::to_vec_pretty(&fixture).unwrap(),
            )
            .unwrap();
        }
    }
}
