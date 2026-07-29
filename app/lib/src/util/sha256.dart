/// SHA-256, written out by hand.
///
/// The app carries exactly one dependency beyond Flutter, and `crypto` would be
/// the second one for a single algorithm we use in a single place. FIPS 180-4
/// is 60 lines; the correctness argument is not "we trust the author", it is the
/// test that hashes random blobs and compares against `shasum -a 256`.
///
/// Incremental on purpose. The thing being hashed is a downloaded binary that is
/// arriving in chunks and is about to be written to disk, so it is hashed as it
/// streams past rather than read back into memory a second time — a verified
/// download should not cost twice the binary's size in RAM.
library;

import 'dart:io';
import 'dart:typed_data';

/// The round constants: the first 32 bits of the fractional parts of the cube
/// roots of the first 64 primes.
const List<int> _k = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

/// A SHA-256 in progress. Feed it [add], read it once with [close].
class Sha256 {
  /// The first 32 bits of the fractional parts of the square roots of the
  /// first eight primes.
  final Uint32List _h = Uint32List.fromList(const [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);

  final Uint8List _block = Uint8List(64);
  final Uint32List _w = Uint32List(64);

  int _pending = 0;
  int _length = 0;
  bool _closed = false;

  /// How many bytes have gone through, which the caller usually already knows
  /// but which makes a length check free.
  int get length => _length;

  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('this Sha256 is already closed');
    }
    _length += chunk.length;
    var i = 0;
    // Top up a partial block first, then take whole blocks straight from the
    // chunk without copying them.
    if (_pending > 0) {
      final want = 64 - _pending;
      final take = chunk.length < want ? chunk.length : want;
      _block.setRange(_pending, _pending + take, chunk);
      _pending += take;
      i = take;
      if (_pending < 64) return;
      _compress(_block, 0);
      _pending = 0;
    }
    while (chunk.length - i >= 64) {
      _compress(chunk, i);
      i += 64;
    }
    if (i < chunk.length) {
      _block.setRange(0, chunk.length - i, chunk, i);
      _pending = chunk.length - i;
    }
  }

  /// The digest, lowercase hex, the way the manifest spells it.
  String close() => _hex(closeBytes());

  /// The digest as 32 raw bytes.
  Uint8List closeBytes() {
    if (_closed) {
      throw StateError('this Sha256 is already closed');
    }
    _closed = true;

    final bits = _length * 8;
    // 0x80, then zeros, then the length as 64 big-endian bits, padded so the
    // whole message is a multiple of 64 bytes.
    final tailLength = _pending < 56 ? 64 : 128;
    final tail = Uint8List(tailLength);
    tail.setRange(0, _pending, _block);
    tail[_pending] = 0x80;
    for (var i = 0; i < 8; i++) {
      tail[tailLength - 1 - i] = (bits >> (8 * i)) & 0xff;
    }
    for (var off = 0; off < tailLength; off += 64) {
      _compress(tail, off);
    }

    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (_h[i] >> 24) & 0xff;
      out[i * 4 + 1] = (_h[i] >> 16) & 0xff;
      out[i * 4 + 2] = (_h[i] >> 8) & 0xff;
      out[i * 4 + 3] = _h[i] & 0xff;
    }
    return out;
  }

  void _compress(List<int> data, int offset) {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] =
          (data[j] << 24) |
          (data[j + 1] << 16) |
          (data[j + 2] << 8) |
          data[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xffffffff & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }

    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
}

const String _digits = '0123456789abcdef';

String _hex(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(_digits[(b >> 4) & 0xf])
      ..write(_digits[b & 0xf]);
  }
  return out.toString();
}

/// One-shot, for things already in memory. The analogue of `sha256_hex`.
String sha256Hex(List<int> bytes) => (Sha256()..add(bytes)).close();

/// Hash a file without holding it in memory. The analogue of `sha256_file`.
///
/// Throws [FileSystemException], which the caller reports verbatim: a binary we
/// cannot read is a binary we cannot vouch for.
Future<String> sha256OfFile(File file) async {
  final hasher = Sha256();
  await for (final chunk in file.openRead()) {
    hasher.add(chunk);
  }
  return hasher.close();
}
