// Dedicated local test funding. Uses the existing setup payer, never custody.
// Saves exact signed bytes exclusively; this program does not broadcast.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use solana_hash::Hash;
use solana_keypair::read_keypair_file;
use solana_message::Message;
use solana_pubkey::Pubkey;
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::{fs, io::Write, path::Path, str::FromStr};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 || !Path::new(&args[1]).is_absolute() || !Path::new(&args[4]).is_absolute() {
        return Err(
            "fund_devnet PRIVATE_DEVNET_DIR BLOCKHASH LAST_VALID_HEIGHT NEW_ATTEMPT_JSON".into(),
        );
    }
    let dir = Path::new(&args[1]);
    let output = Path::new(&args[4]);
    if output.exists() {
        return Err("Saved funding attempt exists; reconcile it before any new signature".into());
    }
    let manifest: Value = serde_json::from_slice(&fs::read(dir.join("setup.json"))?)?;
    let payer_address = "3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ";
    let custody_address = "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX";
    if manifest["network"] != "solana:devnet"
        || manifest["payer"] != payer_address
        || manifest["custody"] != custody_address
    {
        return Err("Different public-test deployment".into());
    }
    let key_path = dir.join("test-authority.keypair.json");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if fs::metadata(&key_path)?.permissions().mode() & 0o077 != 0 {
            return Err("Unsafe tester-key permissions".into());
        }
    }
    let payer = read_keypair_file(key_path).map_err(|_| "Test payer unavailable")?;
    if payer.pubkey().to_string() != payer_address {
        return Err("Test payer mismatch".into());
    }
    let recipient = Pubkey::from_str(custody_address)?;
    let blockhash = Hash::from_str(&args[2])?;
    let height: u64 = args[3].parse()?;
    let instruction =
        solana_system_interface::instruction::transfer(&payer.pubkey(), &recipient, 100_000_000);
    let message = Message::new_with_blockhash(&[instruction], Some(&payer.pubkey()), &blockhash);
    let mut transaction = Transaction::new_unsigned(message);
    transaction.try_sign(&[payer], blockhash)?;
    transaction.verify()?;
    let signature = transaction.signatures[0].to_string();
    let record = json!({"network":"solana:devnet","purpose":"operator_network_fees",
        "payer":payer_address,"recipient":custody_address,"lamports":100_000_000,
        "signature":signature,"transaction":STANDARD.encode(bincode::serialize(&transaction)?),
        "message":STANDARD.encode(transaction.message.serialize()),"lastValidBlockHeight":height});
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
    fs::File::open(output.parent().ok_or("Missing output directory")?)?.sync_all()?;
    println!(
        "{}",
        json!({"signature":signature,"saved":true,"sent":false})
    );
    Ok(())
}
