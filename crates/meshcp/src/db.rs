//! SQLite storage and address allocation.

use anyhow::{Result, anyhow, bail};
use mesh_core::util::{now_rfc3339, now_unix, rfc3339};
use rusqlite::{Connection, OptionalExtension, params};
use std::net::Ipv4Addr;
use std::str::FromStr;
use std::sync::Mutex;

/// A node is shown as online if it has polled within this window.
pub const ONLINE_WINDOW_SECS: i64 = 90;
pub const DEFAULT_SUBNET: &str = "10.201.0.0/16";

pub struct Db {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone)]
pub struct Account {
    pub id: String,
    pub email: String,
    pub password_hash: String,
    pub subnet: String,
    pub derp_region: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct Node {
    pub id: String,
    pub account_id: String,
    pub name: String,
    pub public_key: String,
    pub virtual_ip: String,
    pub created_at: String,
    pub last_seen: Option<i64>,
}

impl Node {
    pub fn online(&self) -> bool {
        self.last_seen
            .map(|t| now_unix() - t < ONLINE_WINDOW_SECS)
            .unwrap_or(false)
    }
}

impl Db {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;

             CREATE TABLE IF NOT EXISTS accounts (
               id            TEXT PRIMARY KEY,
               email         TEXT NOT NULL UNIQUE,
               password_hash TEXT NOT NULL,
               subnet        TEXT NOT NULL,
               created_at    TEXT NOT NULL,
               derp_region   INTEGER
             );

             CREATE TABLE IF NOT EXISTS sessions (
               token      TEXT PRIMARY KEY,
               account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               expires_at INTEGER NOT NULL
             );

             CREATE TABLE IF NOT EXISTS enrollment_keys (
               key        TEXT PRIMARY KEY,
               account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               expires_at INTEGER NOT NULL,
               created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS nodes (
               id         TEXT PRIMARY KEY,
               account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               name       TEXT NOT NULL,
               public_key TEXT NOT NULL UNIQUE,
               virtual_ip TEXT NOT NULL,
               node_token TEXT NOT NULL UNIQUE,
               created_at TEXT NOT NULL,
               last_seen  INTEGER,
               -- The Cloudflare device this node registered for itself. Recorded so removing a
               -- node can also remove that registration; Cloudflare never expires them on its
               -- own, because we speak MASQUE directly and never send the telemetry that would
               -- keep a device looking alive.
               cf_device_id TEXT,
               UNIQUE(account_id, virtual_ip)
             );

             -- Encrypted at rest; see crypto::Sealer.
             CREATE TABLE IF NOT EXISTS backhaul_creds (
               account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               kind       TEXT NOT NULL,
               sealed     BLOB NOT NULL,
               meta       TEXT NOT NULL DEFAULT '',
               updated_at TEXT NOT NULL,
               PRIMARY KEY (account_id, kind)
             );",
        )?;
        // `CREATE TABLE IF NOT EXISTS` does nothing for a database that already exists, so a
        // column added later needs its own step. Failing means it is already there, which is
        // the normal case on every start after the first.
        let _ = conn.execute("ALTER TABLE nodes ADD COLUMN cf_device_id TEXT", []);
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ---- accounts and sessions ----

    pub fn create_account(
        &self,
        email: &str,
        password_hash: &str,
        subnet: &str,
    ) -> Result<Account> {
        let id = crate::crypto::token("acc_");
        let conn = self.lock();
        conn.execute(
            "INSERT INTO accounts (id, email, password_hash, subnet, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, email, password_hash, subnet, now_rfc3339()],
        )
        .map_err(|e| {
            if e.to_string().contains("UNIQUE") {
                anyhow!("an account with that email already exists")
            } else {
                anyhow!(e)
            }
        })?;
        Ok(Account {
            id,
            email: email.to_string(),
            password_hash: password_hash.to_string(),
            subnet: subnet.to_string(),
            derp_region: None,
        })
    }

    pub fn account_by_email(&self, email: &str) -> Result<Option<Account>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT id, email, password_hash, subnet, derp_region FROM accounts WHERE email = ?1",
                params![email],
                |r| {
                    Ok(Account {
                        id: r.get(0)?,
                        email: r.get(1)?,
                        password_hash: r.get(2)?,
                        subnet: r.get(3)?,
                        derp_region: r.get(4)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn account_by_id(&self, id: &str) -> Result<Option<Account>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT id, email, password_hash, subnet, derp_region FROM accounts WHERE id = ?1",
                params![id],
                |r| {
                    Ok(Account {
                        id: r.get(0)?,
                        email: r.get(1)?,
                        password_hash: r.get(2)?,
                        subnet: r.get(3)?,
                        derp_region: r.get(4)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn create_session(&self, account_id: &str, ttl_secs: i64) -> Result<String> {
        let tok = crate::crypto::token("sess_");
        self.lock().execute(
            "INSERT INTO sessions (token, account_id, expires_at) VALUES (?1, ?2, ?3)",
            params![tok, account_id, now_unix() + ttl_secs],
        )?;
        Ok(tok)
    }

    pub fn account_for_session(&self, token: &str) -> Result<Option<Account>> {
        let account_id: Option<String> = self
            .lock()
            .query_row(
                "SELECT account_id FROM sessions WHERE token = ?1 AND expires_at > ?2",
                params![token, now_unix()],
                |r| r.get(0),
            )
            .optional()?;
        match account_id {
            Some(id) => self.account_by_id(&id),
            None => Ok(None),
        }
    }

    pub fn set_subnet(&self, account_id: &str, subnet: &str) -> Result<()> {
        if self.node_count(account_id)? > 0 {
            bail!(
                "cannot change the subnet while nodes are enrolled; every node's address would \
                 move underneath it. Remove the nodes first."
            );
        }
        self.lock().execute(
            "UPDATE accounts SET subnet = ?1 WHERE id = ?2",
            params![subnet, account_id],
        )?;
        Ok(())
    }

    /// Record the network's DERP region, first writer wins.
    ///
    /// First-wins rather than best-wins because agreement matters more than optimality: a
    /// slightly further relay that everyone shares beats a nearer one that isolates a node.
    pub fn set_derp_region_if_unset(&self, account_id: &str, region: u32) -> Result<()> {
        self.lock().execute(
            "UPDATE accounts SET derp_region = ?1 WHERE id = ?2 AND derp_region IS NULL",
            params![region, account_id],
        )?;
        Ok(())
    }

    // ---- enrollment keys ----

    pub fn create_enrollment_key(&self, account_id: &str, ttl_secs: i64) -> Result<(String, i64)> {
        let key = crate::crypto::token("mkey_");
        let expires = now_unix() + ttl_secs;
        self.lock().execute(
            "INSERT INTO enrollment_keys (key, account_id, expires_at, created_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![key, account_id, expires, now_rfc3339()],
        )?;
        Ok((key, expires))
    }

    pub fn account_for_enrollment_key(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT account_id FROM enrollment_keys WHERE key = ?1 AND expires_at > ?2",
                params![key, now_unix()],
                |r| r.get(0),
            )
            .optional()?)
    }

    // ---- nodes ----

    pub fn node_count(&self, account_id: &str) -> Result<usize> {
        let n: i64 = self.lock().query_row(
            "SELECT COUNT(*) FROM nodes WHERE account_id = ?1",
            params![account_id],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    pub fn nodes(&self, account_id: &str) -> Result<Vec<Node>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT id, account_id, name, public_key, virtual_ip, created_at, last_seen
             FROM nodes WHERE account_id = ?1 ORDER BY created_at",
        )?;
        let rows = stmt.query_map(params![account_id], |r| {
            Ok(Node {
                id: r.get(0)?,
                account_id: r.get(1)?,
                name: r.get(2)?,
                public_key: r.get(3)?,
                virtual_ip: r.get(4)?,
                created_at: r.get(5)?,
                last_seen: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn node_by_token(&self, token: &str) -> Result<Option<Node>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT id, account_id, name, public_key, virtual_ip, created_at, last_seen
                 FROM nodes WHERE node_token = ?1",
                params![token],
                |r| {
                    Ok(Node {
                        id: r.get(0)?,
                        account_id: r.get(1)?,
                        name: r.get(2)?,
                        public_key: r.get(3)?,
                        virtual_ip: r.get(4)?,
                        created_at: r.get(5)?,
                        last_seen: r.get(6)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn touch_node(&self, node_id: &str) -> Result<()> {
        self.lock().execute(
            "UPDATE nodes SET last_seen = ?1 WHERE id = ?2",
            params![now_unix(), node_id],
        )?;
        Ok(())
    }

    /// Remember which Cloudflare device belongs to a node, so it can be cleaned up later.
    pub fn set_cf_device(&self, node_id: &str, device_id: &str) -> Result<()> {
        self.lock().execute(
            "UPDATE nodes SET cf_device_id = ?2 WHERE id = ?1 AND IFNULL(cf_device_id, '') <> ?2",
            params![node_id, device_id],
        )?;
        Ok(())
    }

    pub fn cf_device_of(&self, account_id: &str, node_id: &str) -> Result<Option<String>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT cf_device_id FROM nodes WHERE account_id = ?1 AND id = ?2",
                params![account_id, node_id],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    }

    pub fn delete_node(&self, account_id: &str, node_id: &str) -> Result<bool> {
        let n = self.lock().execute(
            "DELETE FROM nodes WHERE account_id = ?1 AND id = ?2",
            params![account_id, node_id],
        )?;
        Ok(n > 0)
    }

    /// Enroll a node, or return its existing record if the same public key comes back.
    ///
    /// Re-enrolling with a known key is idempotent on purpose: a node that loses its token but
    /// keeps its keypair must get the same address back, because the whole point of the address
    /// is that it does not move.
    pub fn enroll_node(
        &self,
        account_id: &str,
        name: &str,
        public_key: &str,
    ) -> Result<(Node, String)> {
        if let Some((node, token)) = self.node_by_public_key(account_id, public_key)? {
            return Ok((node, token));
        }
        let subnet = self
            .account_by_id(account_id)?
            .ok_or_else(|| anyhow!("account vanished"))?
            .subnet;
        let taken = self.taken_addresses(account_id)?;
        let ip = allocate_address(&subnet, &taken)?;

        let id = crate::crypto::token("node_");
        let token = crate::crypto::token("ntok_");
        self.lock().execute(
            "INSERT INTO nodes (id, account_id, name, public_key, virtual_ip, node_token, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![id, account_id, name, public_key, ip.to_string(), token, now_rfc3339()],
        )?;
        Ok((
            Node {
                id,
                account_id: account_id.to_string(),
                name: name.to_string(),
                public_key: public_key.to_string(),
                virtual_ip: ip.to_string(),
                created_at: now_rfc3339(),
                last_seen: None,
            },
            token,
        ))
    }

    fn node_by_public_key(
        &self,
        account_id: &str,
        public_key: &str,
    ) -> Result<Option<(Node, String)>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT id, account_id, name, public_key, virtual_ip, created_at, last_seen, node_token
                 FROM nodes WHERE account_id = ?1 AND public_key = ?2",
                params![account_id, public_key],
                |r| {
                    Ok((
                        Node {
                            id: r.get(0)?,
                            account_id: r.get(1)?,
                            name: r.get(2)?,
                            public_key: r.get(3)?,
                            virtual_ip: r.get(4)?,
                            created_at: r.get(5)?,
                            last_seen: r.get(6)?,
                        },
                        r.get(7)?,
                    ))
                },
            )
            .optional()?)
    }

    fn taken_addresses(&self, account_id: &str) -> Result<Vec<Ipv4Addr>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT virtual_ip FROM nodes WHERE account_id = ?1")?;
        let rows = stmt.query_map(params![account_id], |r| r.get::<_, String>(0))?;
        Ok(rows
            .filter_map(|s| s.ok())
            .filter_map(|s| Ipv4Addr::from_str(&s).ok())
            .collect())
    }

    // ---- backhaul credentials ----

    pub fn put_cred(&self, account_id: &str, kind: &str, sealed: &[u8], meta: &str) -> Result<()> {
        self.lock().execute(
            "INSERT INTO backhaul_creds (account_id, kind, sealed, meta, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(account_id, kind) DO UPDATE
               SET sealed = excluded.sealed, meta = excluded.meta, updated_at = excluded.updated_at",
            params![account_id, kind, sealed, meta, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn get_cred(&self, account_id: &str, kind: &str) -> Result<Option<(Vec<u8>, String)>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT sealed, meta FROM backhaul_creds WHERE account_id = ?1 AND kind = ?2",
                params![account_id, kind],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?)
    }
}

/// Lowest free host address in `subnet`, skipping the network address and `.1`.
///
/// `.1` is reserved by convention for whatever plays gateway, and leaving it free costs nothing
/// while avoiding a surprise if we ever add one.
pub fn allocate_address(subnet: &str, taken: &[Ipv4Addr]) -> Result<Ipv4Addr> {
    let net: ipnet::Ipv4Net = subnet
        .parse()
        .map_err(|e| anyhow!("{subnet} is not a valid IPv4 subnet: {e}"))?;
    let taken: std::collections::HashSet<Ipv4Addr> = taken.iter().copied().collect();

    let first = u32::from(net.network()).saturating_add(2);
    let last = u32::from(net.broadcast());
    for raw in first..last {
        let candidate = Ipv4Addr::from(raw);
        if !taken.contains(&candidate) {
            return Ok(candidate);
        }
    }
    bail!("subnet {subnet} has no free addresses left")
}

/// Reject subnets that would cause obvious trouble.
pub fn validate_subnet(subnet: &str) -> Result<()> {
    let net: ipnet::Ipv4Net = subnet
        .parse()
        .map_err(|e| anyhow!("{subnet} is not a valid IPv4 subnet: {e}"))?;
    if !net.network().is_private() {
        bail!("{subnet} is not a private range; use 10/8, 172.16/12 or 192.168/16");
    }
    if net.prefix_len() > 29 {
        bail!("{subnet} is too small to hold any nodes");
    }
    // Overlapping a backhaul's own range makes routing ambiguous once the TUN is up.
    for reserved in ["100.64.0.0/10", "100.96.0.0/12"] {
        let r: ipnet::Ipv4Net = reserved.parse().expect("constant");
        if net.contains(&r) || r.contains(&net.network()) {
            bail!("{subnet} overlaps {reserved}, which a backhaul already uses");
        }
    }
    Ok(())
}

pub fn timestamp_string(ts: i64) -> String {
    rfc3339(ts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocates_sequentially_and_skips_taken() {
        let taken = vec![Ipv4Addr::new(10, 201, 0, 2), Ipv4Addr::new(10, 201, 0, 3)];
        let got = allocate_address("10.201.0.0/16", &taken).unwrap();
        assert_eq!(got, Ipv4Addr::new(10, 201, 0, 4));
    }

    #[test]
    fn allocation_starts_above_network_and_gateway() {
        let got = allocate_address("10.201.0.0/16", &[]).unwrap();
        assert_eq!(got, Ipv4Addr::new(10, 201, 0, 2));
    }

    #[test]
    fn rejects_public_and_overlapping_subnets() {
        assert!(validate_subnet("10.201.0.0/16").is_ok());
        assert!(validate_subnet("192.168.50.0/24").is_ok());
        assert!(validate_subnet("8.8.8.0/24").is_err());
        assert!(validate_subnet("100.64.0.0/10").is_err());
        assert!(validate_subnet("100.96.0.0/12").is_err());
        assert!(validate_subnet("10.201.0.0/30").is_err());
        assert!(validate_subnet("not-a-subnet").is_err());
    }

    #[test]
    fn enrollment_is_idempotent_for_a_known_key() {
        let db = Db::open(":memory:").unwrap();
        let acc = db.create_account("a@b.c", "hash", DEFAULT_SUBNET).unwrap();
        let (n1, t1) = db.enroll_node(&acc.id, "one", "pubkey-a").unwrap();
        let (n2, t2) = db.enroll_node(&acc.id, "one-again", "pubkey-a").unwrap();
        assert_eq!(n1.virtual_ip, n2.virtual_ip, "address must not move");
        assert_eq!(t1, t2);

        let (n3, _) = db.enroll_node(&acc.id, "two", "pubkey-b").unwrap();
        assert_ne!(n1.virtual_ip, n3.virtual_ip);
    }

    #[test]
    fn subnet_change_blocked_once_nodes_exist() {
        let db = Db::open(":memory:").unwrap();
        let acc = db.create_account("a@b.c", "hash", DEFAULT_SUBNET).unwrap();
        assert!(db.set_subnet(&acc.id, "10.202.0.0/16").is_ok());
        db.enroll_node(&acc.id, "one", "pk").unwrap();
        assert!(db.set_subnet(&acc.id, "10.203.0.0/16").is_err());
    }
}
