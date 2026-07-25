//! Working out what a NAT does to us, so we can predict the port a peer should aim at.
//!
//! The interesting case is a NAT that preserves the source port (external port equals local
//! port) right up until something probes that port from outside before we have bound it, at
//! which point it starts allocating randomly instead. That is the behaviour of at least one real
//! ISP CGNAT, and it flips the problem around: predicting the port is arithmetic, but *not
//! poisoning it* is the part that takes care.
//!
//! Two consequences shape everything here.
//!
//! Predicted addresses are guesses, and a guess aimed at a port the peer has not opened yet is
//! exactly the inbound-before-bind event that destroys port preservation. So predicted candidates
//! are only ever used in reply to a peer that has just told us it is punching, because that
//! message means its socket is bound and its outbound packet has already gone.
//!
//! And a mapping that is already poisoned is detectable: we asked for a specific local port and
//! the world sees a different one. Rebinding elsewhere is then worth more than retrying.

use std::net::{IpAddr, SocketAddr};

/// How a NAT assigns our external port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mapping {
    /// External port equals the local port. Prediction is free.
    PortPreserving,
    /// Same external port whatever we talk to, but not our local port.
    EndpointIndependent,
    /// A different external port per destination. `delta` is the step we measured between two
    /// observations, which is what makes a guess possible at all.
    EndpointDependent { delta: i32 },
    /// Nothing between us and the world, or not enough observations to say.
    Unknown,
}

impl Mapping {
    /// Can a peer reach us at an address we predict rather than one we observed?
    pub fn is_predictable(&self) -> bool {
        !matches!(self, Mapping::Unknown)
    }
}

#[derive(Debug, Clone)]
pub struct NatProfile {
    pub mapping: Mapping,
    /// One reflexive address per STUN server we asked, in the order we asked.
    pub observed: Vec<SocketAddr>,
    pub local_port: u16,
}

impl NatProfile {
    /// Classify from reflexive addresses gathered by asking two or more distinct servers.
    ///
    /// Distinct destinations are the whole point: a NAT that assigns per destination looks
    /// identical to one that does not until you ask twice.
    pub fn classify(local_port: u16, observed: Vec<SocketAddr>) -> Self {
        let mapping = match observed.as_slice() {
            [] => Mapping::Unknown,
            [only] => {
                if only.port() == local_port {
                    Mapping::PortPreserving
                } else {
                    // One sample cannot tell endpoint-independent from endpoint-dependent.
                    Mapping::Unknown
                }
            }
            [first, rest @ ..] => {
                let all_same = rest.iter().all(|a| a.port() == first.port());
                if all_same && first.port() == local_port {
                    Mapping::PortPreserving
                } else if all_same {
                    Mapping::EndpointIndependent
                } else {
                    let last = rest.last().unwrap_or(first);
                    let delta = last.port() as i32 - first.port() as i32;
                    Mapping::EndpointDependent { delta }
                }
            }
        };
        Self {
            mapping,
            observed,
            local_port,
        }
    }

    /// Our public address, if anything observed one.
    pub fn public_ip(&self) -> Option<IpAddr> {
        self.observed.first().map(|a| a.ip())
    }

    /// True when the NAT has stopped preserving our port, which usually means something probed
    /// it from outside before we bound. Rebinding to a fresh local port is the way out.
    pub fn looks_poisoned(&self) -> bool {
        match self.observed.as_slice() {
            [] => false,
            obs => obs.iter().all(|a| a.port() != self.local_port) && obs.len() > 1,
        }
    }

    /// Addresses a peer could try, beyond the ones we actually observed.
    ///
    /// `spread` bounds how many sequential guesses to make. Every extra guess is another packet
    /// aimed at a port nobody has opened, so this stays small on purpose.
    pub fn predicted_candidates(&self, spread: u16) -> Vec<SocketAddr> {
        let Some(ip) = self.public_ip() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let mut push = |addr: SocketAddr| {
            if !out.contains(&addr) {
                out.push(addr);
            }
        };

        match self.mapping {
            Mapping::PortPreserving | Mapping::Unknown => {
                // The common case, and the one worth guessing first: a fresh destination gets
                // our local port again.
                push(SocketAddr::new(ip, self.local_port));
            }
            Mapping::EndpointIndependent => {
                // Nothing to predict; the observed address already covers every destination.
            }
            Mapping::EndpointDependent { delta } => {
                // Port preservation may still hold for a destination that has not been used, so
                // try it before extrapolating.
                push(SocketAddr::new(ip, self.local_port));
                if let Some(last) = self.observed.last() {
                    let step = if delta == 0 { 1 } else { delta };
                    for k in 1..=spread as i32 {
                        let p = last.port() as i32 + step * k;
                        if (1..=65535).contains(&p) {
                            push(SocketAddr::new(ip, p as u16));
                        }
                    }
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn port_preserving_is_recognised() {
        let p = NatProfile::classify(
            47778,
            vec![addr("203.0.113.1:47778"), addr("203.0.113.1:47778")],
        );
        assert_eq!(p.mapping, Mapping::PortPreserving);
        assert!(!p.looks_poisoned());
        assert_eq!(
            p.predicted_candidates(4),
            vec![addr("203.0.113.1:47778")],
            "the prediction is simply our own port"
        );
    }

    #[test]
    fn endpoint_independent_needs_no_prediction() {
        let p = NatProfile::classify(
            47778,
            vec![addr("203.0.113.1:51000"), addr("203.0.113.1:51000")],
        );
        assert_eq!(p.mapping, Mapping::EndpointIndependent);
        assert!(p.predicted_candidates(4).is_empty());
    }

    #[test]
    fn endpoint_dependent_extrapolates_from_the_step() {
        let p = NatProfile::classify(
            47778,
            vec![addr("203.0.113.1:51000"), addr("203.0.113.1:51002")],
        );
        assert_eq!(p.mapping, Mapping::EndpointDependent { delta: 2 });
        let got = p.predicted_candidates(3);
        // Port preservation is tried first, then the extrapolation.
        assert_eq!(got[0], addr("203.0.113.1:47778"));
        assert!(got.contains(&addr("203.0.113.1:51004")));
        assert!(got.contains(&addr("203.0.113.1:51006")));
    }

    #[test]
    fn a_poisoned_mapping_is_visible() {
        // We asked for 47778 and the world consistently sees something else.
        let p = NatProfile::classify(
            47778,
            vec![addr("203.0.113.1:33000"), addr("203.0.113.1:34000")],
        );
        assert!(p.looks_poisoned());
    }

    #[test]
    fn one_observation_is_not_enough_to_classify() {
        let p = NatProfile::classify(47778, vec![addr("203.0.113.1:51000")]);
        assert_eq!(p.mapping, Mapping::Unknown);
        assert!(!p.looks_poisoned(), "one sample must not trigger a rebind");
    }

    #[test]
    fn predictions_stay_inside_the_port_range() {
        let p = NatProfile::classify(
            47778,
            vec![addr("203.0.113.1:65530"), addr("203.0.113.1:65534")],
        );
        assert!(
            p.predicted_candidates(8).iter().all(|a| a.port() > 0),
            "wrapped past the end of the port range"
        );
    }

    #[test]
    fn the_isp_case_that_motivated_this() {
        // A real ISP CGNAT: 1:1 port preserving, so binding 7777 gets you external 7777, right
        // up until something probes 7777 from outside before you bind. After that the same bind
        // gets a random port instead. Both states have to be distinguishable, because the first
        // is trivially predictable and the second calls for moving to a different local port.
        let healthy = NatProfile::classify(
            7777,
            vec![addr("203.0.113.5:7777"), addr("203.0.113.5:7777")],
        );
        assert_eq!(healthy.mapping, Mapping::PortPreserving);
        assert!(!healthy.looks_poisoned());
        assert_eq!(
            healthy.predicted_candidates(4),
            vec![addr("203.0.113.5:7777")]
        );

        let poisoned = NatProfile::classify(
            7777,
            vec![addr("203.0.113.5:41234"), addr("203.0.113.5:9876")],
        );
        assert!(matches!(
            poisoned.mapping,
            Mapping::EndpointDependent { .. }
        ));
        assert!(
            poisoned.looks_poisoned(),
            "a poisoned mapping must be visible, or we keep binding a port that will never work"
        );
    }

    #[test]
    fn no_observations_means_no_guesses() {
        let p = NatProfile::classify(47778, vec![]);
        assert_eq!(p.mapping, Mapping::Unknown);
        assert!(p.predicted_candidates(4).is_empty());
    }
}
