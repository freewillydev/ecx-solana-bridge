// Transitional signing entry point. Remove when the Haskell signer is integrated.
use std::io::{self, Read};
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || args[1] != "--config" {
        std::process::exit(64);
    }
    let config = std::fs::read(&args[2]).unwrap_or_default();
    let mut request = Vec::new();
    if io::stdin().take(8193).read_to_end(&mut request).is_err() {
        std::process::exit(1);
    }
    let mut output = [0u8; 8192];
    let mut length = 0;
    let status = unsafe {
        ecx_solana_sdk::ecx_solana_prepare_v1(
            config.as_ptr(),
            config.len(),
            request.as_ptr(),
            request.len(),
            output.as_mut_ptr(),
            output.len(),
            &mut length,
        )
    };
    if status != 0 {
        std::process::exit(1);
    }
    use std::io::Write;
    if io::stdout().write_all(&output[..length]).is_err() {
        std::process::exit(1);
    }
}
