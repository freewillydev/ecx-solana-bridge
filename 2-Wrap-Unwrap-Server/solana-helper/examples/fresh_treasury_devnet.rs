// Isolated fresh-custody acceptance setup. Existing real Devnet mint; no minting.
// Saves exact bytes before submission (performed separately by the test driver).
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use solana_hash::Hash;
use solana_keypair::{read_keypair_file, write_keypair_file, Keypair};
use solana_message::Message;
use solana_pubkey::Pubkey;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::{
    address::get_associated_token_address_with_program_id,
    instruction::create_associated_token_account_idempotent,
};
use std::{fs, io::Write, path::Path, str::FromStr};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 || !Path::new(&args[1]).is_absolute() || !Path::new(&args[2]).is_absolute() {
        return Err("fresh_treasury_devnet EXISTING_PRIVATE_DEVNET_DIR NEW_PRIVATE_DIR BLOCKHASH LAST_VALID_HEIGHT".into());
    }
    let source = Path::new(&args[1]);
    let dest = Path::new(&args[2]);
    fs::create_dir_all(dest)?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(dest, fs::Permissions::from_mode(0o700))?;
    let output = dest.join("funding.json");
    if output.exists() {
        return Err("Existing funding bytes: reconcile them instead of signing again".into());
    }
    let manifest: Value = serde_json::from_slice(&fs::read(source.join("setup.json"))?)?;
    if manifest["network"] != "solana:devnet"
        || manifest["mint"] != "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM"
    {
        return Err("Different Devnet setup".into());
    }
    let load = |name: &str| -> Result<Keypair, Box<dyn std::error::Error>> {
        let path = source.join(format!("{name}.keypair.json"));
        if fs::metadata(&path)?.permissions().mode() & 0o077 != 0 {
            return Err("Unsafe test key permissions".into());
        }
        read_keypair_file(path).map_err(|_| "Test funding key unavailable".into())
    };
    let payer = load("test-authority")?;
    let tester = load("tester")?;
    if payer.pubkey().to_string() != manifest["payer"].as_str().ok_or("Missing payer")?
        || tester.pubkey().to_string() != manifest["tester"].as_str().ok_or("Missing tester")?
    {
        return Err("Funding key identity mismatch".into());
    }
    let keypath = dest.join("custody.keypair.json");
    let custody = if keypath.exists() {
        read_keypair_file(&keypath).map_err(|_| "Custody key unavailable")?
    } else {
        let k = Keypair::new();
        write_keypair_file(&k, &keypath)?;
        fs::set_permissions(&keypath, fs::Permissions::from_mode(0o600))?;
        k
    };
    let mint = Pubkey::from_str(manifest["mint"].as_str().ok_or("Missing mint")?)?;
    let program = spl_token_interface::id();
    let ata = get_associated_token_address_with_program_id(&custody.pubkey(), &mint, &program);
    let source_ata =
        get_associated_token_address_with_program_id(&tester.pubkey(), &mint, &program);
    let instructions = vec![
        create_associated_token_account_idempotent(
            &payer.pubkey(),
            &custody.pubkey(),
            &mint,
            &program,
        ),
        spl_token_interface::instruction::transfer_checked(
            &program,
            &source_ata,
            &mint,
            &ata,
            &tester.pubkey(),
            &[],
            1_000_000,
            8,
        )?,
        solana_system_interface::instruction::transfer(
            &payer.pubkey(),
            &custody.pubkey(),
            50_000_000,
        ),
    ];
    let hash = Hash::from_str(&args[3])?;
    let height: u64 = args[4].parse()?;
    let mut tx = Transaction::new_unsigned(Message::new_with_blockhash(
        &instructions,
        Some(&payer.pubkey()),
        &hash,
    ));
    tx.try_sign(&[&payer, &tester], hash)?;
    tx.verify()?;
    let bytes = bincode::serialize(&tx)?;
    if bytes.len() > 1232 {
        return Err("Funding packet too large".into());
    }
    let record = json!({"network":"solana:devnet","mint":mint.to_string(),"custodyOwner":custody.pubkey().to_string(),"custodyAta":ata.to_string(),"tokenUnits":"1000000","lamports":"50000000","signature":tx.signatures[0].to_string(),"transaction":STANDARD.encode(bytes),"lastValidBlockHeight":height,"sent":false});
    let mut options = fs::OpenOptions::new();
    options.create_new(true).write(true);
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
    let mut file = options.open(output)?;
    file.write_all(&serde_json::to_vec_pretty(&record)?)?;
    file.sync_all()?;
    fs::File::open(dest)?.sync_all()?;
    println!(
        "{}",
        json!({"saved":true,"sent":false,"custodyOwner":custody.pubkey().to_string(),"custodyAta":ata.to_string()})
    );
    Ok(())
}
