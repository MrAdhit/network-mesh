//! Password hashing, opaque tokens, and encryption for the backhaul credentials.

use anyhow::{Result, anyhow};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64U};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit},
};

/// A random opaque token, url-safe.
pub fn token(prefix: &str) -> String {
    let raw: [u8; 24] = rand::random();
    format!("{prefix}{}", B64U.encode(raw))
}

pub fn hash_password(password: &str) -> Result<String> {
    use argon2::password_hash::{PasswordHasher, SaltString, rand_core::OsRng};
    let salt = SaltString::generate(&mut OsRng);
    argon2::Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| anyhow!("hashing password failed: {e}"))
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    use argon2::password_hash::{PasswordHash, PasswordVerifier};
    PasswordHash::new(hash)
        .map(|parsed| {
            argon2::Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .is_ok()
        })
        .unwrap_or(false)
}

/// Encrypts the users' Cloudflare and Tailscale tokens before they touch the database.
///
/// Those grant real access to someone's vendor accounts, which is a different risk class from
/// the rest of this project's state, so they do not sit in the clear even in an MVP. The key
/// comes from MESH_CP_SECRET; a random one is generated if unset, which makes existing rows
/// unreadable after a restart. That is deliberate: losing credentials is better than silently
/// persisting them under a key nobody chose.
pub struct Sealer {
    cipher: XChaCha20Poly1305,
}

impl Sealer {
    pub fn from_env() -> Self {
        let key = match std::env::var("MESH_CP_SECRET") {
            Ok(s) if !s.is_empty() => {
                let mut k = [0u8; 32];
                let digest = blake_ish(s.as_bytes());
                k.copy_from_slice(&digest);
                k
            }
            _ => {
                tracing::warn!(
                    "MESH_CP_SECRET is unset; generating an ephemeral key. Stored backhaul \
                     credentials will not survive a restart."
                );
                rand::random()
            }
        };
        Self {
            cipher: XChaCha20Poly1305::new(&key.into()),
        }
    }

    pub fn seal(&self, plaintext: &str) -> Result<Vec<u8>> {
        let nonce_bytes: [u8; 24] = rand::random();
        let nonce = XNonce::from(nonce_bytes);
        let mut out = nonce_bytes.to_vec();
        let ct = self
            .cipher
            .encrypt(&nonce, plaintext.as_bytes())
            .map_err(|e| anyhow!("sealing failed: {e}"))?;
        out.extend_from_slice(&ct);
        Ok(out)
    }

    pub fn open(&self, sealed: &[u8]) -> Result<String> {
        if sealed.len() < 24 {
            return Err(anyhow!("sealed value is too short"));
        }
        let (nonce_bytes, ct) = sealed.split_at(24);
        let nonce: [u8; 24] = nonce_bytes.try_into().expect("checked length above");
        let pt = self.cipher.decrypt(&XNonce::from(nonce), ct).map_err(|_| {
            anyhow!("could not decrypt stored credential; was MESH_CP_SECRET changed?")
        })?;
        Ok(String::from_utf8(pt)?)
    }
}

/// Stretch an arbitrary passphrase into 32 bytes.
///
/// Not a KDF and not pretending to be one; it only turns a config string into a key of the right
/// length. Argon2 guards the thing that matters, which is user passwords.
fn blake_ish(input: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut acc: u64 = 0xcbf2_9ce4_8422_2325;
    for (i, b) in input.iter().enumerate() {
        acc ^= *b as u64;
        acc = acc.wrapping_mul(0x1000_0000_01b3);
        out[i % 32] ^= (acc >> ((i % 8) * 8)) as u8;
    }
    for (i, byte) in out.iter_mut().enumerate() {
        acc = acc.wrapping_mul(0x1000_0000_01b3) ^ (i as u64);
        *byte = byte.wrapping_add((acc >> 24) as u8);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passwords_round_trip() {
        let h = hash_password("correct horse").unwrap();
        assert!(verify_password("correct horse", &h));
        assert!(!verify_password("wrong horse", &h));
    }

    #[test]
    fn sealing_round_trips_and_rejects_tampering() {
        unsafe { std::env::set_var("MESH_CP_SECRET", "test-secret") };
        let s = Sealer::from_env();
        let sealed = s.seal("tskey-api-secret").unwrap();
        assert_eq!(s.open(&sealed).unwrap(), "tskey-api-secret");

        let mut bad = sealed.clone();
        let last = bad.len() - 1;
        bad[last] ^= 0xff;
        assert!(s.open(&bad).is_err());
    }

    #[test]
    fn tokens_are_unique_and_prefixed() {
        let a = token("mesh_");
        let b = token("mesh_");
        assert_ne!(a, b);
        assert!(a.starts_with("mesh_"));
    }
}
