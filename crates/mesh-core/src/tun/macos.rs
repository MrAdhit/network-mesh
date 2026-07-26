//! macOS utun.
//!
//! There is no `/dev/net/tun` here. A utun is a socket opened against the kernel control named
//! `com.apple.net.utun_control`: look the control up by name to get its id, then `connect` to
//! it with a unit number. Unit 0 means "any free one", and since the kernel then chooses the
//! interface number, the name has to be read back rather than assumed.
//!
//! The other difference that matters is framing. Linux with `IFF_NO_PI` hands over bare IP
//! packets; a utun prefixes every packet with a four-byte address family in network order. That
//! prefix is added on write and stripped on read here, so callers see the same bare IP packets
//! on both platforms.

use anyhow::{Context, Result, bail};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use tokio::io::unix::AsyncFd;

use super::{MTU, run, utun};

const UTUN_CONTROL_NAME: &[u8] = b"com.apple.net.utun_control\0";

pub struct TunDevice {
    fd: AsyncFd<OwnedFd>,
    /// Kept so `Drop` can take the loopback alias back off again.
    address: std::net::Ipv4Addr,
    pub name: String,
}

/// Give the mesh address a loopback path, so this node can reach its own mesh address.
///
/// macOS creates the `LOCAL` route that delivers a packet to the local stack only when an
/// address is assigned to an interface. On a utun the point-to-point destination is our own
/// address, and the interface route it produces takes the slot that `LOCAL` route would have
/// had. The result is an address that is bindable and reachable from peers, but with no path
/// from this machine to itself: `ping <our own address>` is written into the tunnel, and the
/// daemon drops it because no *peer* owns it. Linux and Windows both hand us that path for
/// free. Aliasing onto lo0 is what creates it here; no `route add` can, because the flag comes
/// from assigning an address and nothing else.
///
/// Not fatal if it fails. Losing this costs the node a self-ping, which is a smoke test rather
/// than a working mesh, and refusing to start over it would be a poor trade.
fn alias_onto_loopback(address: std::net::Ipv4Addr, net: ipnet::Ipv4Net) {
    // Clear whatever the mesh left on lo0 first, including this same address from a previous
    // run: aliasing an address that is already there fails, and `Drop` never runs when the
    // daemon is killed rather than shut down. A node that has since changed subnets would
    // otherwise go on claiming an address it no longer holds, for as long as the machine is up.
    match std::process::Command::new("ifconfig").arg("lo0").output() {
        Ok(out) => {
            for stale in utun::loopback_mesh_aliases(&String::from_utf8_lossy(&out.stdout), net) {
                let _ = run("ifconfig", &["lo0", "-alias", &stale.to_string()]);
            }
        }
        Err(e) => tracing::debug!(error = %e, "could not read lo0 to clear old mesh aliases"),
    }

    match run(
        "ifconfig",
        &["lo0", "alias", &address.to_string(), "255.255.255.255"],
    ) {
        Ok(()) => tracing::debug!(%address, "aliased onto lo0 for local delivery"),
        Err(e) => tracing::warn!(
            error = %e,
            %address,
            "could not alias the mesh address onto lo0; peers can still reach this node, but it \
             cannot reach its own mesh address"
        ),
    }
}

impl TunDevice {
    /// Open a utun and configure it with the node's address and the mesh subnet route.
    ///
    /// `requested` is honoured only when it names a specific unit (`utun7`). Anything else,
    /// including the `mesh0` we use on Linux, asks the kernel for whatever is free, because
    /// macOS will not let us name the interface ourselves.
    pub fn open(requested: &str, address: std::net::Ipv4Addr, subnet: &str) -> Result<Self> {
        let unit = utun::unit(requested);

        let raw: RawFd =
            unsafe { libc::socket(libc::PF_SYSTEM, libc::SOCK_DGRAM, libc::SYSPROTO_CONTROL) };
        if raw < 0 {
            return Err(std::io::Error::last_os_error())
                .context("opening a PF_SYSTEM socket for utun");
        }
        let owned = unsafe { OwnedFd::from_raw_fd(raw) };

        // Resolve the control name to the id we then connect to.
        let mut info: libc::ctl_info = unsafe { std::mem::zeroed() };
        for (i, b) in UTUN_CONTROL_NAME.iter().enumerate() {
            info.ctl_name[i] = *b as libc::c_char;
        }
        if unsafe { libc::ioctl(owned.as_raw_fd(), libc::CTLIOCGINFO, &mut info) } < 0 {
            return Err(std::io::Error::last_os_error())
                .context("looking up the utun kernel control");
        }

        let addr = libc::sockaddr_ctl {
            sc_len: std::mem::size_of::<libc::sockaddr_ctl>() as u8,
            sc_family: libc::AF_SYSTEM as u8,
            ss_sysaddr: libc::AF_SYS_CONTROL as u16,
            sc_id: info.ctl_id,
            sc_unit: unit,
            sc_reserved: [0; 5],
        };
        let rc = unsafe {
            libc::connect(
                owned.as_raw_fd(),
                &addr as *const libc::sockaddr_ctl as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_ctl>() as libc::socklen_t,
            )
        };
        if rc < 0 {
            let err = std::io::Error::last_os_error();
            let hint = if err.raw_os_error() == Some(libc::EPERM) {
                "; creating a utun needs root, so run meshd with sudo"
            } else if unit != 0 {
                "; that utun unit may already be in use"
            } else {
                ""
            };
            return Err(err).context(format!("connecting to the utun control{hint}"));
        }

        // The kernel chose the interface, so ask it which one.
        let mut name_buf = [0u8; 32];
        let mut name_len = name_buf.len() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                owned.as_raw_fd(),
                libc::SYSPROTO_CONTROL,
                libc::UTUN_OPT_IFNAME,
                name_buf.as_mut_ptr() as *mut libc::c_void,
                &mut name_len,
            )
        };
        if rc < 0 {
            return Err(std::io::Error::last_os_error()).context("reading back the utun name");
        }
        let name = String::from_utf8_lossy(&name_buf[..name_len.saturating_sub(1) as usize])
            .trim_end_matches('\0')
            .to_string();
        if name.is_empty() {
            bail!("the kernel gave the utun no name");
        }

        // Non-blocking, so AsyncFd can drive it.
        let flags = unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(std::io::Error::last_os_error()).context("setting O_NONBLOCK on the utun");
        }

        // A utun is point-to-point, so ifconfig wants a local and a remote address. Pointing it
        // at itself is the usual trick when there is no single peer on the other end.
        //
        // Address and MTU go in separate invocations. Combining them works on some releases and
        // not others, and a partly-applied ifconfig is harder to diagnose than two clear errors.
        let net: ipnet::Ipv4Net = subnet
            .parse()
            .with_context(|| format!("{subnet} is not a valid IPv4 subnet"))?;
        let addr = address.to_string();
        run("ifconfig", &[&name, "inet", &addr, &addr, "up"])?;
        run("ifconfig", &[&name, "mtu", &MTU.to_string()])?;
        // `route add` fails if the route exists; delete first and ignore that failing.
        let _ = run(
            "route",
            &["-n", "delete", "-net", subnet, "-interface", &name],
        );
        run("route", &["-n", "add", "-net", subnet, "-interface", &name])?;
        alias_onto_loopback(address, net);

        tracing::info!(name, %address, subnet, mtu = MTU, "utun interface up");
        Ok(Self {
            fd: AsyncFd::new(owned)?,
            address,
            name,
        })
    }

    /// Read one IP packet, dropping the utun address-family header.
    pub async fn recv(&self) -> Result<Vec<u8>> {
        loop {
            let mut guard = self.fd.readable().await?;
            let mut buf = vec![0u8; MTU as usize + 64 + utun::HEADER_LEN];
            let res = guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.get_ref().as_raw_fd(),
                        buf.as_mut_ptr() as *mut libc::c_void,
                        buf.len(),
                    )
                };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            });
            match res {
                Ok(Ok(n)) => {
                    buf.truncate(n);
                    match utun::strip(&buf) {
                        Some(pkt) => return Ok(pkt.to_vec()),
                        None => continue, // header only, nothing to forward
                    }
                }
                Ok(Err(e)) => return Err(e.into()),
                Err(_would_block) => continue,
            }
        }
    }

    /// Hand one IP packet to the kernel, adding the address-family header it expects.
    pub async fn send(&self, packet: &[u8]) -> Result<()> {
        // IPv6 would need AF_INET6 here; the mesh is IPv4 only for now and node.rs drops
        // anything else before it reaches this point.
        let framed = utun::frame(packet);

        loop {
            let mut guard = self.fd.writable().await?;
            let res = guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.get_ref().as_raw_fd(),
                        framed.as_ptr() as *const libc::c_void,
                        framed.len(),
                    )
                };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
            match res {
                Ok(r) => return r.map_err(Into::into),
                Err(_would_block) => continue,
            }
        }
    }
}

impl Drop for TunDevice {
    fn drop(&mut self) {
        // The utun goes away with the fd, but a lo0 alias is machine state that outlives the
        // process. Left behind, it makes this machine answer for a mesh address it no longer
        // holds. Startup clears these too, since a killed daemon never gets here.
        let _ = run("ifconfig", &["lo0", "-alias", &self.address.to_string()]);
    }
}
