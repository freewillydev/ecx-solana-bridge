// Separate operator setup tool. Not installed with the custody helper.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use solana_hash::Hash;
use solana_keypair::{read_keypair_file, write_keypair_file, Keypair};
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::{
    address::get_associated_token_address_with_program_id,
    instruction::create_associated_token_account_idempotent,
};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
    str::FromStr,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn rpc(method: &str, params: Value) -> Result<Value> {
    let mut child = Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--fail",
            "--max-time",
            "20",
            "--header",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
            "https://api.devnet.solana.com",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    child.stdin.take().ok_or("missing input pipe")?.write_all(
        json!({"jsonrpc":"2.0","id":1,"method":method,"params":params})
            .to_string()
            .as_bytes(),
    )?;
    let out = child.wait_with_output()?;
    if !out.status.success() || out.stdout.len() > 1048576 {
        return Err("Devnet RPC transport failed".into());
    }
    let v: Value = serde_json::from_slice(&out.stdout)?;
    if v.get("error").is_some() {
        return Err(format!("Devnet RPC {method} failed: {}", v["error"]["code"]).into());
    }
    Ok(v["result"].clone())
}
fn key(dir: &Path, name: &str) -> Result<Keypair> {
    let p = dir.join(format!("{name}.keypair.json"));
    if p.exists() {
        return read_keypair_file(p).map_err(|_| "private test key unavailable".into());
    }
    let k = Keypair::new();
    write_keypair_file(&k, &p)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(p, fs::Permissions::from_mode(0o600))?;
    }
    Ok(k)
}
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 || !Path::new(&args[1]).is_absolute() {
        return Err("Pass an absolute private test-state directory".into());
    }
    let dir = Path::new(&args[1]);
    fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    if rpc("getGenesisHash", json!([]))? != "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG" {
        return Err("Wrong Devnet genesis".into());
    }
    let payer = key(dir, "test-authority")?;
    let custody = key(dir, "custody")?;
    let tester = key(dir, "tester")?;
    let mint = key(dir, "mint")?;
    let token = spl_token_interface::id();
    let custody_ata =
        get_associated_token_address_with_program_id(&custody.pubkey(), &mint.pubkey(), &token);
    let tester_ata =
        get_associated_token_address_with_program_id(&tester.pubkey(), &mint.pubkey(), &token);
    let mut manifest = json!({"network":"solana:devnet","mint":mint.pubkey().to_string(),"payer":payer.pubkey().to_string(),"custody":custody.pubkey().to_string(),"tester":tester.pubkey().to_string(),"custodyAta":custody_ata.to_string(),"testerAta":tester_ata.to_string(),"decimals":8,"tokenProgram":token.to_string(),"completed":false});
    let manifest_path = dir.join("setup.json");
    if manifest_path.exists() {
        let old: Value = serde_json::from_slice(&fs::read(&manifest_path)?)?;
        for field in [
            "network",
            "mint",
            "payer",
            "custody",
            "tester",
            "custodyAta",
            "testerAta",
        ] {
            if old[field] != manifest[field] {
                return Err("Existing test setup does not match these keys".into());
            }
        }
    } else {
        fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest)?)?;
    }
    let pending = dir.join("setup-attempt.json");
    if pending.exists() {
        let record: Value = serde_json::from_slice(&fs::read(&pending)?)?;
        let signature = record["signature"]
            .as_str()
            .ok_or("missing saved signature")?;
        let status = rpc(
            "getSignatureStatuses",
            json!([[signature],{"searchTransactionHistory":true}]),
        )?;
        if status["value"][0]["confirmationStatus"] == "finalized"
            && status["value"][0]["err"].is_null()
        {
            manifest["completed"] = json!(true);
            manifest["setupSignature"] = json!(signature);
            fs::write(
                dir.join("setup.json"),
                serde_json::to_vec_pretty(&manifest)?,
            )?;
            println!("{manifest}");
            return Ok(());
        }
        println!(
            "{}",
            json!({"status":"existing_attempt_requires_reconciliation","signature":signature})
        );
        return Err(
            "Never create a fresh setup transaction while an earlier outcome is unknown".into(),
        );
    }
    // Reconcile a possibly sent transaction before considering remaining funds.
    let balance = rpc(
        "getBalance",
        json!([payer.pubkey().to_string(),{"commitment":"finalized"}]),
    )?["value"]
        .as_u64()
        .ok_or("invalid balance")?;
    if balance < 20_000_000 {
        println!(
            "{}",
            json!({"fundingAddress":payer.pubkey().to_string(),"balanceLamports":balance,"required":"0.02 Devnet SOL"})
        );
        return Err("Devnet funding required; no transaction sent".into());
    }
    if !rpc(
        "getAccountInfo",
        json!([mint.pubkey().to_string(),{"commitment":"finalized"}]),
    )?["value"]
        .is_null()
    {
        return Err("Mint already exists without setup journal; inspect before proceeding".into());
    }
    let rent = rpc("getMinimumBalanceForRentExemption", json!([82]))?
        .as_u64()
        .ok_or("invalid rent")?;
    let ix = vec![
        solana_system_interface::instruction::create_account(
            &payer.pubkey(),
            &mint.pubkey(),
            rent,
            82,
            &token,
        ),
        spl_token_interface::instruction::initialize_mint2(
            &token,
            &mint.pubkey(),
            &payer.pubkey(),
            None,
            8,
        )?,
        create_associated_token_account_idempotent(
            &payer.pubkey(),
            &custody.pubkey(),
            &mint.pubkey(),
            &token,
        ),
        create_associated_token_account_idempotent(
            &payer.pubkey(),
            &tester.pubkey(),
            &mint.pubkey(),
            &token,
        ),
        spl_token_interface::instruction::mint_to_checked(
            &token,
            &mint.pubkey(),
            &custody_ata,
            &payer.pubkey(),
            &[],
            100_000_000_000,
            8,
        )?,
        spl_token_interface::instruction::mint_to_checked(
            &token,
            &mint.pubkey(),
            &tester_ata,
            &payer.pubkey(),
            &[],
            100_000_000_000,
            8,
        )?,
        solana_system_interface::instruction::transfer(
            &payer.pubkey(),
            &custody.pubkey(),
            5_000_000,
        ),
        solana_system_interface::instruction::transfer(
            &payer.pubkey(),
            &tester.pubkey(),
            1_000_000,
        ),
    ];
    let latest = rpc("getLatestBlockhash", json!([{"commitment":"confirmed"}]))?;
    let blockhash = Hash::from_str(
        latest["value"]["blockhash"]
            .as_str()
            .ok_or("missing blockhash")?,
    )?;
    let message = Message::new_with_blockhash(&ix, Some(&payer.pubkey()), &blockhash);
    let mut tx = Transaction::new_unsigned(message);
    tx.try_sign(&[&payer, &mint], blockhash)?;
    let bytes = bincode::serialize(&tx)?;
    if bytes.len() > 1232 {
        return Err("setup transaction exceeds packet limit".into());
    }
    let signature = tx.signatures[0].to_string();
    let encoded = STANDARD.encode(bytes);
    let record = json!({"signature":signature,"transaction":encoded,"lastValidBlockHeight":latest["value"]["lastValidBlockHeight"],"state":"possibly_broadcast"});
    let mut file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&pending)?;
    file.write_all(serde_json::to_string_pretty(&record)?.as_bytes())?;
    file.sync_all()?;
    fs::File::open(dir)?.sync_all()?;
    let actual = rpc(
        "sendTransaction",
        json!([encoded,{"encoding":"base64","skipPreflight":false,"maxRetries":0}]),
    )?;
    if actual != signature {
        return Err("RPC returned a different transaction identifier".into());
    }
    println!(
        "{}",
        json!({"submitted":signature,"status":"rerun_after_finalization_to_verify"})
    );
    Ok(())
}
