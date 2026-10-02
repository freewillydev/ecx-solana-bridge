// A dedicated public-Devnet acceptance client, never the bridge's signer.
// Validate the app's unsigned transaction with the SDK, sign with the existing
// tester key, and fsync exact bytes. Network submission is a separate operation.
use base64::{engine::general_purpose::STANDARD, Engine};
use bincode::Options;
use serde_json::{json, Value};
use solana_hash::Hash;
use solana_instruction::AccountMeta;
use solana_keypair::read_keypair_file;
use solana_message::Message;
use solana_pubkey::Pubkey;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::address::get_associated_token_address_with_program_id;
use std::{fs, io::Write, path::Path, str::FromStr};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or("missing prepared field".into())
}
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if !(args.len() == 4 || args.len() == 5)
        || args[1..].iter().any(|p| !Path::new(p).is_absolute())
    {
        return Err("deposit_devnet PRIVATE_DEVNET_DIR PREPARED_JSON NEW_ATTEMPT_JSON [EXPLICIT_TEST_CONFIG]".into());
    }
    let dir = Path::new(&args[1]);
    let output = Path::new(&args[3]);
    if output.exists() {
        return Err(
            "Saved deposit attempt exists; reconcile its exact bytes before any new signing".into(),
        );
    }
    let bytes = fs::read(&args[2])?;
    if bytes.len() > 8192 {
        return Err("Prepared transaction is too large".into());
    }
    let prepared: Value = serde_json::from_slice(&bytes)?;
    let manifest: Value = serde_json::from_slice(&fs::read(dir.join("setup.json"))?)?;
    if manifest["network"] != "solana:devnet"
        || manifest["mint"] != "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM"
        || manifest["custody"] != "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX"
        || manifest["tester"] != "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
        || prepared["chain"] != "solana:devnet"
        || prepared["amount"] != "10000"
        || prepared["mint"] != manifest["mint"]
        || prepared["owner"] != manifest["tester"]
    {
        return Err("Different public-test deployment or amount".into());
    }
    // Optional explicit acceptance target; existing funding/tester identities
    // stay fixed. This changes neither the custody helper nor production API.
    let target = if args.len() == 5 {
        let raw = fs::read(&args[4])?;
        if raw.len() > 32768 {
            return Err("Test config too large".into());
        }
        let config: Value = serde_json::from_slice(&raw)?;
        if config["profile"] != "L2LSignetDevnet" || config["mint"] != manifest["mint"] {
            return Err("Different explicit test network or mint".into());
        }
        config
    } else {
        json!({"custodyOwner":manifest["custody"],"custodyAta":manifest["custodyAta"],"deploymentId":"l2l-devnet-local"})
    };
    let target_owner = Pubkey::from_str(text(&target, "custodyOwner")?)?;
    let target_ata = get_associated_token_address_with_program_id(
        &target_owner,
        &Pubkey::from_str(text(&manifest, "mint")?)?,
        &spl_token_interface::id(),
    );
    if target_ata.to_string() != text(&target, "custodyAta")?
        || prepared["custody"] != target["custodyAta"]
    {
        return Err("Prepared deposit differs from explicit custody target".into());
    }
    let order = text(&prepared, "orderId")?;
    if order.len() != 64
        || !order
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err("Invalid order identifier".into());
    }
    let memo = format!(
        "ecx-bridge:v1:{}:deposit:{order}",
        text(&target, "deploymentId")?
    );
    let pay_reference = prepared.get("reference").and_then(Value::as_str);
    if pay_reference.is_none() && text(&prepared, "memo")? != memo {
        return Err("Memo does not bind the expected order".into());
    }
    let key_path = dir.join("tester.keypair.json");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if fs::metadata(&key_path)?.permissions().mode() & 0o077 != 0 {
            return Err("Unsafe tester-key permissions".into());
        }
    }
    let tester = read_keypair_file(key_path).map_err(|_| "Tester key unavailable")?;
    if tester.pubkey().to_string() != text(&manifest, "tester")? {
        return Err("Tester key mismatch".into());
    }
    let mint = Pubkey::from_str(text(&manifest, "mint")?)?;
    let custody = target_owner;
    let token = spl_token_interface::id();
    let source = get_associated_token_address_with_program_id(&tester.pubkey(), &mint, &token);
    let destination = get_associated_token_address_with_program_id(&custody, &mint, &token);
    let blockhash = Hash::from_str(text(&prepared, "blockhash")?)?;
    let mut transfer = spl_token_interface::instruction::transfer_checked(
        &token,
        &source,
        &mint,
        &destination,
        &tester.pubkey(),
        &[],
        10000,
        8,
    )?;
    let mut instructions = vec![];
    if let Some(reference) = pay_reference {
        let raw: Vec<u8> = (0..64)
            .step_by(2)
            .map(|i| u8::from_str_radix(&order[i..i + 2], 16))
            .collect::<std::result::Result<_, _>>()?;
        let expected =
            Pubkey::new_from_array(raw.try_into().map_err(|_| "Invalid reference bytes")?);
        if expected.to_string() != reference {
            return Err("Reference differs from order".into());
        }
        transfer
            .accounts
            .push(AccountMeta::new_readonly(expected, false));
    }
    instructions.push(transfer);
    if pay_reference.is_none() {
        instructions.push(spl_memo_interface::instruction::build_memo(
            &spl_memo_interface::v3::id(),
            memo.as_bytes(),
            &[&tester.pubkey()],
        ));
    }
    let expected = Message::new_with_blockhash(&instructions, Some(&tester.pubkey()), &blockhash);
    let mut transaction = if pay_reference.is_some() {
        Transaction::new_unsigned(expected)
    } else {
        let serialized = STANDARD.decode(text(&prepared, "transaction")?)?;
        if serialized.len() > 1232 {
            return Err("Transaction exceeds packet limit".into());
        }
        let transaction: Transaction = bincode::DefaultOptions::new()
            .with_fixint_encoding()
            .with_limit(1232)
            .reject_trailing_bytes()
            .deserialize(&serialized)?;
        if transaction.message != expected
            || transaction.signatures.len() != 1
            || transaction.signatures[0].as_ref().iter().any(|b| *b != 0)
        {
            return Err("Unsigned transaction differs from the exact expected deposit".into());
        }
        transaction
    };
    transaction.try_sign(&[tester], blockhash)?;
    transaction.verify()?;
    let signature = transaction.signatures[0].to_string();
    let record = json!({"network":"solana:devnet","orderId":order,"amount":"10000",
        "signature":signature,"transaction":STANDARD.encode(bincode::serialize(&transaction)?),
        "lastValidBlockHeight":prepared["lastValidBlockHeight"],"phase":"possibly_broadcast"});
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(output)?;
    file.write_all(&serde_json::to_vec_pretty(&record)?)?;
    file.sync_all()?;
    fs::File::open(output.parent().ok_or("Missing attempt directory")?)?.sync_all()?;
    println!(
        "{}",
        json!({"signature":signature,"saved":true,"sent":false})
    );
    Ok(())
}
