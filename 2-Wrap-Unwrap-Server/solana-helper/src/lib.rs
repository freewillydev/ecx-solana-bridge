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
use std::{fs, str::FromStr};

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
// Separate administration preview: no key paths, signatures, RPC or custody API.
#[derive(Deserialize)]
#[serde(untagged)]
enum AdminRequest { Token(TokenRequest), Address(MetadataAddressRequest) }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MetadataAddressRequest { protocol:u8, verb:AddressVerb, mint:String, owner:Option<String> }
#[derive(Deserialize)]
enum AddressVerb { #[serde(rename="metadata_address")] MetadataAddress, #[serde(rename="associated_address")] AssociatedAddress }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenRequest {
    protocol: u8,
    verb: TokenVerb,
    authority: String,
    mint: Option<String>,
    account: Option<String>,
    owner: Option<String>,
    amount: Option<String>,
    metadata: Option<MetadataRequest>,
    seed: Option<String>,
    rent: Option<String>,
    blockhash: String,
    #[serde(rename="nonceAccount")]
    nonce_account: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum TokenVerb { Mint, Burn, Create, Metadata, Associated, NonceMint, CreateNonce }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MetadataRequest {
    create: bool, address: String, name: String, symbol: String, uri: String, max_cost: String,
}
fn metadata_instruction(r: &TokenRequest) -> Result<solana_instruction::Instruction, &'static str> {
    use solana_instruction::{Instruction,AccountMeta};
    let m = r.metadata.as_ref().ok_or("missing_metadata")?;
    if r.account.is_some() || r.amount.is_some() || r.seed.is_some() || r.rent.is_some()
        || m.name.is_empty() || m.name.len()>32 || m.symbol.is_empty() || m.symbol.len()>10 || m.uri.len()>200 {
        return Err("invalid_metadata_fields");
    }
    raw_amount(&m.max_cost)?;
    let mint=key(r.mint.as_deref().ok_or("missing_mint")?)?;
    let authority=key(&r.authority)?;
    let program=key("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")?;
    let metadata=metadata_address(&mint, &program);
    if metadata.to_string()!=m.address { return Err("metadata_address_mismatch"); }
    // Metaplex CreateMetadataAccountV3 / UpdateMetadataAccountV2 Borsh wire format.
    // Golden messages come from the official mpl-token-metadata 5.1.1 builders.
    let mut data=if m.create { vec![33] } else { vec![15,1] };
    for text in [&m.name,&m.symbol,&m.uri] {
        data.extend_from_slice(&(text.len() as u32).to_le_bytes());
        data.extend_from_slice(text.as_bytes());
    }
    data.extend_from_slice(&[0;5]); // zero royalty; no creators, collection, uses
    data.extend_from_slice(if m.create { &[1,0][..] } else { &[0,0,0][..] });
    let accounts=if m.create { vec![AccountMeta::new(metadata,false),AccountMeta::new_readonly(mint,false),
        AccountMeta::new_readonly(authority,true),AccountMeta::new(authority,true),
        AccountMeta::new_readonly(authority,true),AccountMeta::new_readonly(Pubkey::default(),false)] }
        else { vec![AccountMeta::new(metadata,false),AccountMeta::new_readonly(authority,true)] };
    Ok(Instruction { program_id:program,accounts,data })
}
fn metadata_address(mint: &Pubkey, program: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[b"metadata",program.as_ref(),mint.as_ref()],program).0
}

fn prepare_token(r: &TokenRequest) -> Result<String, &'static str> {
    if r.protocol != 1 { return Err("invalid_protocol"); }
    if r.nonce_account.is_some() != matches!(r.verb, TokenVerb::NonceMint | TokenVerb::CreateNonce) {
        return Err("invalid_nonce_fields");
    }
    let authority = key(&r.authority)?;
    if matches!(r.verb, TokenVerb::CreateNonce) {
        let nonce=key(r.nonce_account.as_deref().ok_or("missing_nonce")?)?;
        let owner=key(r.owner.as_deref().ok_or("missing_nonce_authority")?)?;
        let seed=r.seed.as_deref().ok_or("missing_nonce_seed")?;
        let rent=raw_amount(r.rent.as_deref().ok_or("missing_nonce_rent")?)?;
        if r.mint.is_some() || r.account.is_some() || r.amount.is_some() || r.metadata.is_some()
            || seed.is_empty() || seed.len()>32 || !authority.is_on_curve() || !owner.is_on_curve()
            || Pubkey::create_with_seed(&authority,seed,&Pubkey::default()).map_err(|_| "invalid_seed")? != nonce {
            return Err("invalid_nonce_creation");
        }
        let instructions=solana_system_interface::instruction::create_nonce_account_with_seed(
            &authority,&nonce,&authority,seed,&owner,rent);
        let hash=Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
        let message=Message::new_with_blockhash(&instructions,Some(&authority),&hash);
        return bincode::serialize(&Transaction::new_unsigned(message)).map(|bytes| STANDARD.encode(bytes))
            .map_err(|_| "serialization_failed");
    }
    let mint = key(r.mint.as_deref().ok_or("missing_mint")?)?;
    let program = spl_token_interface::id();
    let blockhash = Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    if matches!(r.verb, TokenVerb::Associated) {
        let owner=key(r.owner.as_deref().ok_or("missing_account_owner")?)?;
        let account=key(r.account.as_deref().ok_or("missing_token_account")?)?;
        if !authority.is_on_curve() || !owner.is_on_curve() || mint==owner || mint==authority
            || r.amount.is_some() || r.seed.is_some() || r.metadata.is_some()
            || account!=get_associated_token_address_with_program_id(&owner,&mint,&program) {
            return Err("invalid_associated_account");
        }
        raw_amount(r.rent.as_deref().ok_or("missing_account_rent")?)?;
        let instruction=create_associated_token_account_idempotent(&authority,&owner,&mint,&program);
        let message=Message::new_with_blockhash(&[instruction],Some(&authority),&blockhash);
        return bincode::serialize(&Transaction::new_unsigned(message)).map(|bytes| STANDARD.encode(bytes))
            .map_err(|_| "serialization_failed");
    }
    if r.owner.is_some() { return Err("unexpected_account_owner"); }
    if matches!(r.verb, TokenVerb::Metadata) {
        if !authority.is_on_curve() { return Err("invalid_metadata_authority"); }
        let instruction=metadata_instruction(r)?;
        let message=Message::new_with_blockhash(&[instruction],Some(&authority),&blockhash);
        return bincode::serialize(&Transaction::new_unsigned(message)).map(|bytes| STANDARD.encode(bytes))
            .map_err(|_| "serialization_failed");
    }
    if r.metadata.is_some() { return Err("unexpected_metadata"); }
    if matches!(r.verb, TokenVerb::Create) {
        let seed = r.seed.as_deref().ok_or("missing_mint_seed")?;
        let rent = raw_amount(r.rent.as_deref().ok_or("missing_mint_rent")?)?;
        if r.account.is_some() || r.amount.is_some() || seed.is_empty() || seed.len()>32 || !authority.is_on_curve()
            || Pubkey::create_with_seed(&authority, seed, &program).map_err(|_| "invalid_seed")? != mint {
            return Err("invalid_mint_creation");
        }
        let instructions = [solana_system_interface::instruction::create_account_with_seed(
            &authority, &mint, &authority, seed, rent, 82, &program),
            spl_token_interface::instruction::initialize_mint2(&program, &mint, &authority, None, 8)
                .map_err(|_| "invalid_mint_initialization")?];
        let message=Message::new_with_blockhash(&instructions,Some(&authority),&blockhash);
        return bincode::serialize(&Transaction::new_unsigned(message)).map(|bytes| STANDARD.encode(bytes))
            .map_err(|_| "serialization_failed");
    }
    if r.seed.is_some() || r.rent.is_some() { return Err("unexpected_creation_fields"); }
    let account = key(r.account.as_deref().ok_or("missing_token_account")?)?;
    let program = spl_token_interface::id();
    if !authority.is_on_curve() || [mint, account, program].contains(&authority)
        || mint == account || mint == program || account == program {
        return Err("invalid_admin_accounts");
    }
    let amount = raw_amount(r.amount.as_deref().ok_or("missing_amount")?)?;
    let instruction = match r.verb {
        TokenVerb::Mint | TokenVerb::NonceMint => spl_token_interface::instruction::mint_to_checked(
            &program, &mint, &account, &authority, &[], amount, 8),
        TokenVerb::Burn => spl_token_interface::instruction::burn_checked(
            &program, &account, &mint, &authority, &[], amount, 8),
        TokenVerb::Create | TokenVerb::Metadata | TokenVerb::Associated | TokenVerb::CreateNonce => return Err("invalid_admin_instruction"),
    }.map_err(|_| "invalid_admin_instruction")?;
    let blockhash = Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    let mut instructions=Vec::new();
    if let Some(nonce)=r.nonce_account.as_deref() {
        instructions.push(solana_system_interface::instruction::advance_nonce_account(&key(nonce)?, &authority));
    }
    instructions.push(instruction);
    let message = Message::new_with_blockhash(&instructions, Some(&authority), &blockhash);
    let bytes = bincode::serialize(&Transaction::new_unsigned(message)).map_err(|_| "serialization_failed")?;
    if bytes.len() > 1232 { return Err("transaction_too_large"); }
    Ok(STANDARD.encode(bytes))
}

// The caller owns every buffer. No Rust allocation or pointer escapes this ABI.
// Status: 0 = reply JSON, 1 = fixed error code, 2 = invalid buffers/capacity.
// SAFETY: nonnull buffers must be valid for their lengths, aligned as declared,
// and disjoint; output_len must point to a writable usize. No pointers are retained.
#[no_mangle]
pub unsafe extern "C" fn ecx_solana_prepare_v1(
    config: *const u8,
    config_len: usize,
    request: *const u8,
    request_len: usize,
    output: *mut u8,
    capacity: usize,
    output_len: *mut usize,
) -> i32 {
    unsafe { prepare_ffi(0, config, config_len, request, request_len, output, capacity, output_len) }
}

// Same caller-owned buffer and pointer requirements as ecx_solana_prepare_v1.
#[no_mangle]
pub unsafe extern "C" fn ecx_token_prepare_v1(
    config: *const u8, config_len: usize, request: *const u8, request_len: usize,
    output: *mut u8, capacity: usize, output_len: *mut usize,
) -> i32 {
    unsafe { prepare_ffi(1, config, config_len, request, request_len, output, capacity, output_len) }
}
// Read-only pool address derivation; no instruction, key or RPC input.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PoolAddressRequest {protocol:u8,config:String,mint_a:String,mint_b:String,fee_tier_index:u16}
#[no_mangle]
pub unsafe extern "C" fn ecx_pool_address_v1(
    config: *const u8, config_len: usize, request: *const u8, request_len: usize,
    output: *mut u8, capacity: usize, output_len: *mut usize,
) -> i32 {
    unsafe { prepare_ffi(2, config, config_len, request, request_len, output, capacity, output_len) }
}
// Unsigned classic Orca InitializePool, pinned client f4b99e79. No keys or RPC.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PoolCreateRequest {
    protocol:u8, config:String, payer:String, mint_a:String, mint_b:String,
    vault_a:String, vault_b:String, sqrt_price:String, blockhash:String,
}
fn prepare_pool(r:PoolCreateRequest)->Result<serde_json::Value,&'static str> {
    use solana_instruction::{AccountMeta as A,Instruction};
    let config=key(&r.config)?; let payer=key(&r.payer)?;
    let a=key(&r.mint_a)?; let b=key(&r.mint_b)?;
    let va=key(&r.vault_a)?; let vb=key(&r.vault_b)?;
    let price=r.sqrt_price.parse::<u128>().map_err(|_| "invalid_pool_price")?;
    if r.protocol!=1 || a>=b || price.to_string()!=r.sqrt_price
        || !(4295048016..=79226673515401279992447579055).contains(&price)
        || ![payer,va,vb].iter().all(Pubkey::is_on_curve) { return Err("invalid_pool_request"); }
    let program=key("whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc")?;
    let spacing=32896u16.to_le_bytes();
    let (pool,bump)=Pubkey::find_program_address(&[b"whirlpool",config.as_ref(),a.as_ref(),b.as_ref(),&spacing],&program);
    let tier=Pubkey::find_program_address(&[b"fee_tier",config.as_ref(),&spacing],&program).0;
    let accounts=vec![A::new_readonly(config,false),A::new_readonly(a,false),A::new_readonly(b,false),
        A::new(payer,true),A::new(pool,false),A::new(va,true),A::new(vb,true),A::new_readonly(tier,false),
        A::new_readonly(spl_token_interface::id(),false),A::new_readonly(Pubkey::default(),false),
        A::new_readonly(key("SysvarRent111111111111111111111111111111111")?,false)];
    let mut identities=accounts.iter().map(|a|a.pubkey).collect::<Vec<_>>(); identities.push(program);
    identities.sort(); identities.dedup();
    if identities.len()!=12 { return Err("duplicate_pool_account"); }
    let mut data=vec![95,180,10,172,84,174,232,40,bump];
    data.extend_from_slice(&spacing); data.extend_from_slice(&price.to_le_bytes());
    let hash=Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    let message=Message::new_with_blockhash(&[Instruction{program_id:program,accounts,data}],Some(&payer),&hash);
    let bytes=bincode::serialize(&Transaction::new_unsigned(message)).map_err(|_| "serialization_failed")?;
    if bytes.len()>1232 { return Err("transaction_too_large"); }
    Ok(serde_json::json!({"pool":pool.to_string(),"feeTier":tier.to_string(),"bump":bump,"transaction":STANDARD.encode(bytes)}))
}
#[no_mangle]
pub unsafe extern "C" fn ecx_pool_prepare_v1(
    config:*const u8,config_len:usize,request:*const u8,request_len:usize,
    output:*mut u8,capacity:usize,output_len:*mut usize,
)->i32 { unsafe { prepare_ffi(3,config,config_len,request,request_len,output,capacity,output_len) } }
// Atomic full-range position opening plus idempotent dynamic boundary arrays.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PositionRequest {protocol:u8,payer:String,pool:String,position_mint:String,blockhash:String}
fn prepare_position(r:PositionRequest)->Result<serde_json::Value,&'static str> {
    use solana_instruction::{AccountMeta as A,Instruction};
    let payer=key(&r.payer)?; let pool=key(&r.pool)?; let mint=key(&r.position_mint)?;
    if r.protocol!=1 || payer==mint || !payer.is_on_curve() || !mint.is_on_curve() { return Err("invalid_position_request"); }
    let program=key("whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc")?;
    let token=spl_token_interface::id(); let system=Pubkey::default();
    let (position,bump)=Pubkey::find_program_address(&[b"position",mint.as_ref()],&program);
    let account=get_associated_token_address_with_program_id(&payer,&mint,&token);
    let starts=[-2894848i32,0];
    let arrays=starts.map(|start|Pubkey::find_program_address(&[b"tick_array",pool.as_ref(),start.to_string().as_bytes()],&program).0);
    let mut instructions=Vec::new();
    for (start,array) in starts.into_iter().zip(arrays) {
        let mut data=vec![41,33,165,200,120,231,142,50]; data.extend_from_slice(&start.to_le_bytes()); data.push(1);
        instructions.push(Instruction {program_id:program,accounts:vec![A::new_readonly(pool,false),A::new(payer,true),A::new(array,false),A::new_readonly(system,false)],data});
    }
    let accounts=vec![A::new(payer,true),A::new_readonly(payer,false),A::new(position,false),A::new(mint,true),
        A::new(account,false),A::new_readonly(pool,false),A::new_readonly(token,false),A::new_readonly(system,false),
        A::new_readonly(key("SysvarRent111111111111111111111111111111111")?,false),
        A::new_readonly(key("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")?,false)];
    let mut data=vec![135,128,47,77,15,152,240,49,bump];
    data.extend_from_slice(&(-427648i32).to_le_bytes()); data.extend_from_slice(&427648i32.to_le_bytes());
    instructions.push(Instruction {program_id:program,accounts,data});
    let hash=Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    let message=Message::new_with_blockhash(&instructions,Some(&payer),&hash);
    if message.account_keys.len()!=12 || message.header.num_required_signatures!=2 { return Err("position_account_collision"); }
    let bytes=bincode::serialize(&Transaction::new_unsigned(message)).map_err(|_| "serialization_failed")?;
    if bytes.len()>1232 { return Err("transaction_too_large"); }
    Ok(serde_json::json!({"position":position.to_string(),"tokenAccount":account.to_string(),"lowerArray":arrays[0].to_string(),
        "upperArray":arrays[1].to_string(),"bump":bump,"transaction":STANDARD.encode(bytes)}))
}
#[no_mangle]
pub unsafe extern "C" fn ecx_position_prepare_v1(
    config:*const u8,config_len:usize,request:*const u8,request_len:usize,
    output:*mut u8,capacity:usize,output_len:*mut usize,
)->i32 { unsafe { prepare_ffi(4,config,config_len,request,request_len,output,capacity,output_len) } }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LiquidityRequest {protocol:u8,verb:String,owner:String,pool:String,position_mint:String,
    mint_a:String,mint_b:String,vault_a:String,vault_b:String,liquidity:String,amount_a:String,amount_b:String,blockhash:String}
fn prepare_liquidity(r:LiquidityRequest)->Result<serde_json::Value,&'static str> {
    use solana_instruction::{AccountMeta as A,Instruction};
    let owner=key(&r.owner)?; let pool=key(&r.pool)?; let mint=key(&r.position_mint)?;
    let a=key(&r.mint_a)?; let b=key(&r.mint_b)?; let va=key(&r.vault_a)?; let vb=key(&r.vault_b)?;
    let liquidity=r.liquidity.parse::<u128>().map_err(|_| "invalid_liquidity")?;
    let amount_a=r.amount_a.parse::<u64>().map_err(|_| "invalid_limit")?; let amount_b=r.amount_b.parse::<u64>().map_err(|_| "invalid_limit")?;
    let collect=r.verb=="collect";
    if r.protocol!=1 || !owner.is_on_curve() || a>=b || liquidity.to_string()!=r.liquidity
        || amount_a.to_string()!=r.amount_a || amount_b.to_string()!=r.amount_b
        || (collect && (amount_a!=0 || amount_b!=0))
        || (!collect && (liquidity==0 || (r.verb!="deposit" && r.verb!="withdraw"))) { return Err("invalid_liquidity_request"); }
    let program=key("whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc")?; let token=spl_token_interface::id();
    let position=Pubkey::find_program_address(&[b"position",mint.as_ref()],&program).0;
    let nft=get_associated_token_address_with_program_id(&owner,&mint,&token);
    let oa=get_associated_token_address_with_program_id(&owner,&a,&token); let ob=get_associated_token_address_with_program_id(&owner,&b,&token);
    let arrays=[-2894848i32,0].map(|start|Pubkey::find_program_address(&[b"tick_array",pool.as_ref(),start.to_string().as_bytes()],&program).0);
    let mut instructions=Vec::new();
    if collect {
        if liquidity>0 { instructions.push(Instruction {program_id:program,accounts:vec![A::new(pool,false),A::new(position,false),A::new_readonly(arrays[0],false),A::new_readonly(arrays[1],false)],data:vec![154,230,250,13,236,209,75,223]}); }
        instructions.push(Instruction {program_id:program,accounts:vec![A::new_readonly(pool,false),A::new_readonly(owner,true),A::new(position,false),A::new_readonly(nft,false),A::new(oa,false),A::new(va,false),A::new(ob,false),A::new(vb,false),A::new_readonly(token,false)],data:vec![164,152,207,99,30,186,19,182]});
    } else {
        let accounts=vec![A::new(pool,false),A::new_readonly(token,false),A::new_readonly(owner,true),A::new(position,false),A::new_readonly(nft,false),A::new(oa,false),A::new(ob,false),A::new(va,false),A::new(vb,false),A::new(arrays[0],false),A::new(arrays[1],false)];
        let mut data=if r.verb=="deposit" {vec![46,156,243,118,13,205,251,178]} else {vec![160,38,208,111,104,91,44,1]};
        data.extend_from_slice(&liquidity.to_le_bytes()); data.extend_from_slice(&amount_a.to_le_bytes()); data.extend_from_slice(&amount_b.to_le_bytes());
        instructions.push(Instruction {program_id:program,accounts,data});
    }
    let hash=Hash::from_str(&r.blockhash).map_err(|_| "invalid_blockhash")?;
    let message=Message::new_with_blockhash(&instructions,Some(&owner),&hash);
    if message.account_keys.len()!=(if collect && liquidity==0 {10} else {12}) || message.header.num_required_signatures!=1 { return Err("liquidity_account_collision"); }
    let bytes=bincode::serialize(&Transaction::new_unsigned(message)).map_err(|_| "serialization_failed")?;
    if bytes.len()>1232 { return Err("transaction_too_large"); }
    Ok(serde_json::json!({"position":position.to_string(),"positionToken":nft.to_string(),"ownerA":oa.to_string(),"ownerB":ob.to_string(),
        "lowerArray":arrays[0].to_string(),"upperArray":arrays[1].to_string(),"transaction":STANDARD.encode(bytes)}))
}
#[no_mangle]
pub unsafe extern "C" fn ecx_liquidity_prepare_v1(
    config:*const u8,config_len:usize,request:*const u8,request_len:usize,
    output:*mut u8,capacity:usize,output_len:*mut usize,
)->i32 { unsafe { prepare_ffi(5,config,config_len,request,request_len,output,capacity,output_len) } }
unsafe fn prepare_ffi(
    mode: u8, config: *const u8, config_len: usize, request: *const u8, request_len: usize,
    output: *mut u8, capacity: usize, output_len: *mut usize,
) -> i32 {
    if output_len.is_null() {
        return 2;
    }
    unsafe {
        *output_len = 0;
    }
    if config.is_null()
        || request.is_null()
        || output.is_null()
        || config_len > 4096
        || request_len > 8192
        || capacity > 8192
    {
        return 2;
    }
    let result = std::panic::catch_unwind(|| {
        if mode == 5 {
            if unsafe { std::slice::from_raw_parts(config,config_len) } != b"{}" { return Err("invalid_liquidity_config"); }
            let r=serde_json::from_slice(unsafe { std::slice::from_raw_parts(request,request_len) }).map_err(|_| "invalid_liquidity_request")?;
            return serde_json::to_vec(&prepare_liquidity(r)?).map_err(|_| "serialization_failed");
        }
        if mode == 4 {
            if unsafe { std::slice::from_raw_parts(config,config_len) } != b"{}" { return Err("invalid_position_config"); }
            let r=serde_json::from_slice(unsafe { std::slice::from_raw_parts(request,request_len) }).map_err(|_| "invalid_position_request")?;
            return serde_json::to_vec(&prepare_position(r)?).map_err(|_| "serialization_failed");
        }
        if mode == 3 {
            if unsafe { std::slice::from_raw_parts(config,config_len) } != b"{}" { return Err("invalid_pool_config"); }
            let r=serde_json::from_slice(unsafe { std::slice::from_raw_parts(request,request_len) }).map_err(|_| "invalid_pool_request")?;
            return serde_json::to_vec(&prepare_pool(r)?).map_err(|_| "serialization_failed");
        }
        if mode == 2 {
            if unsafe { std::slice::from_raw_parts(config, config_len) } != b"{}" { return Err("invalid_pool_config"); }
            let r: PoolAddressRequest=serde_json::from_slice(unsafe { std::slice::from_raw_parts(request,request_len) })
                .map_err(|_| "invalid_pool_request")?;
            let config=key(&r.config)?; let a=key(&r.mint_a)?; let b=key(&r.mint_b)?;
            if r.protocol!=1 || a>=b { return Err("invalid_pool_mints"); }
            let program=key("whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc")?;
            let address=Pubkey::find_program_address(&[b"whirlpool",config.as_ref(),a.as_ref(),b.as_ref(),&r.fee_tier_index.to_le_bytes()],&program).0;
            return serde_json::to_vec(&address.to_string()).map_err(|_| "serialization_failed");
        }
        if mode == 1 {
            if unsafe { std::slice::from_raw_parts(config, config_len) } != b"{}" {
                return Err("invalid_admin_config");
            }
            let request: AdminRequest = serde_json::from_slice(unsafe { std::slice::from_raw_parts(request, request_len) })
                .map_err(|_| "invalid_admin_request")?;
            let reply=match request {
                AdminRequest::Token(r)=>prepare_token(&r)?,
                AdminRequest::Address(MetadataAddressRequest {protocol,verb,mint,owner})=>{
                    if protocol!=1 { return Err("invalid_protocol"); }
                    let mint=key(&mint)?;
                    match verb {
                        AddressVerb::MetadataAddress=>{
                            if owner.is_some() { return Err("unexpected_account_owner"); }
                            let program=key("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")?;
                            metadata_address(&mint,&program).to_string()
                        }
                        AddressVerb::AssociatedAddress=>{
                            let owner=key(owner.as_deref().ok_or("missing_account_owner")?)?;
                            if !owner.is_on_curve() { return Err("invalid_account_owner"); }
                            get_associated_token_address_with_program_id(&owner,&mint,&spl_token_interface::id()).to_string()
                        }
                    }
                }
            };
            return serde_json::to_vec(&reply).map_err(|_| "serialization_failed");
        }
        let config: Config =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(config, config_len) })
                .map_err(|_| "invalid_config")?;
        let request: Request =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(request, request_len) })
                .map_err(|_| "invalid_request")?;
        serde_json::to_vec(&prepare(&config, &request)?).map_err(|_| "serialization_failed")
    })
    .unwrap_or(Err("sdk_panicked"));
    let (status, bytes) = match result {
        Ok(bytes) => (0, bytes),
        Err(code) => (1, code.as_bytes().to_vec()),
    };
    if bytes.len() > capacity {
        return 2;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        *output_len = bytes.len();
    }
    status
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
    fn ffi_bounds_fail_without_writing_output() {
        let input = b"{}";
        for (config_len, request_len, capacity) in
            [(4097, 2, 8192), (2, 8193, 8192), (2, 2, 8193), (2, 2, 0)]
        {
            let mut output = [0xa5; 8192];
            let mut length = 99;
            let status = unsafe {
                ecx_solana_prepare_v1(
                    input.as_ptr(),
                    config_len,
                    input.as_ptr(),
                    request_len,
                    output.as_mut_ptr(),
                    capacity,
                    &mut length,
                )
            };
            assert_eq!(status, 2);
            assert_eq!(length, 0);
            assert!(output.iter().all(|byte| *byte == 0xa5));
        }
        let mut length = 99;
        let status = unsafe {
            ecx_solana_prepare_v1(
                std::ptr::null(),
                0,
                input.as_ptr(),
                2,
                std::ptr::null_mut(),
                0,
                &mut length,
            )
        };
        assert_eq!(status, 2);
        assert_eq!(length, 0);
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
    use std::path::Path;
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
