//! Linux `/dev/net/tun`.
//!
//! The simple case: one device node, configured by ioctl, carrying bare IP packets because we
//! ask for `IFF_NO_PI`.

use anyhow::{Context, Result, bail};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use tokio::io::unix::AsyncFd;

use super::{MTU, run};

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const IFF_TUN: libc::c_short = 0x0001;
const IFF_NO_PI: libc::c_short = 0x1000;

#[repr(C)]
struct IfReq {
    name: [libc::c_char; libc::IFNAMSIZ],
    flags: libc::c_short,
    _pad: [u8; 22],
}

pub struct TunDevice {
    fd: AsyncFd<OwnedFd>,
    pub name: String,
}

impl TunDevice {
    /// Open a TUN device and configure it with the node's address and the mesh subnet route.
    pub fn open(name: &str, address: std::net::Ipv4Addr, subnet: &str) -> Result<Self> {
        if name.len() >= libc::IFNAMSIZ {
            bail!("interface name {name} is too long");
        }
        let raw: RawFd = unsafe {
            libc::open(
                c"/dev/net/tun".as_ptr(),
                libc::O_RDWR | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if raw < 0 {
            return Err(std::io::Error::last_os_error()).context(
                "opening /dev/net/tun; the container needs --device /dev/net/tun and CAP_NET_ADMIN",
            );
        }
        let owned = unsafe { OwnedFd::from_raw_fd(raw) };

        let mut req = IfReq {
            name: [0; libc::IFNAMSIZ],
            flags: IFF_TUN | IFF_NO_PI,
            _pad: [0; 22],
        };
        for (i, b) in name.as_bytes().iter().enumerate() {
            req.name[i] = *b as libc::c_char;
        }
        let rc = unsafe { libc::ioctl(owned.as_raw_fd(), TUNSETIFF, &mut req) };
        if rc < 0 {
            return Err(std::io::Error::last_os_error()).context("TUNSETIFF failed");
        }

        // Configuring the interface via iproute2 rather than a pile of further ioctls: the
        // container already has it, and the commands are legible in a log when they fail.
        run("ip", &["link", "set", "dev", name, "mtu", &MTU.to_string()])?;
        run(
            "ip",
            &["addr", "add", &format!("{address}/32"), "dev", name],
        )?;
        run("ip", &["link", "set", "dev", name, "up"])?;
        // Route the whole mesh subnet at the interface; per-peer routing happens above.
        run("ip", &["route", "replace", subnet, "dev", name])?;

        tracing::info!(name, %address, subnet, mtu = MTU, "tun interface up");
        Ok(Self {
            fd: AsyncFd::new(owned)?,
            name: name.to_string(),
        })
    }

    /// Read one IP packet from the kernel.
    pub async fn recv(&self) -> Result<Vec<u8>> {
        loop {
            let mut guard = self.fd.readable().await?;
            let mut buf = vec![0u8; MTU as usize + 64];
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
                    return Ok(buf);
                }
                Ok(Err(e)) => return Err(e.into()),
                Err(_would_block) => continue,
            }
        }
    }

    /// Hand one IP packet to the kernel as if it had arrived on the wire.
    pub async fn send(&self, packet: &[u8]) -> Result<()> {
        loop {
            let mut guard = self.fd.writable().await?;
            let res = guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.get_ref().as_raw_fd(),
                        packet.as_ptr() as *const libc::c_void,
                        packet.len(),
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
