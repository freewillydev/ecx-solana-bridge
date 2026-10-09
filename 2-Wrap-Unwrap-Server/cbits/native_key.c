#include <secp256k1.h>
#include <string.h>

/* Fixed-size buffers are checked by the Haskell boundary. All secret scalar
 * arithmetic and public-key generation belong to libsecp256k1, not this shim.
 * Return the PARENT public key for the BIP32 child fingerprint. */
int ecx_native_child(const unsigned char *parent, const unsigned char *tweak,
                     const unsigned char *randomness, unsigned char *child,
                     unsigned char *public_key) {
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_pubkey pub;
    size_t size = 33;
    int ok = secp256k1_context_randomize(ctx, randomness)
          && secp256k1_ec_seckey_verify(ctx, parent);
    if (ok) {
        memcpy(child, parent, 32);
        ok = secp256k1_ec_seckey_tweak_add(ctx, child, tweak)
          && secp256k1_ec_pubkey_create(ctx, &pub, parent)
          && secp256k1_ec_pubkey_serialize(ctx, public_key, &size, &pub,
                                         SECP256K1_EC_COMPRESSED);
    }
    secp256k1_context_destroy(ctx);
    if (!ok) {
        memset(child, 0, 32);
        memset(public_key, 0, 33);
    }
    return ok;
}
