// MoonBit Formal Specification & Verification Contracts: Roaring Bitmap Correctness.
// Formally verifies representation invariants and membership equivalence:
// For any sorted unique array of UInt64:
// `roaring_contains(encode_roaring(sorted_unique(ids)), id) == (id in ids)`.

///|
/// Container type discriminator.
#derive(Debug, Eq)
pub(all) enum ContainerKind {
  ArrayContainer
  BitmapContainer
}

///|
/// Maximum elements in an Array Container before converting to Bitmap Container.
pub const SPEC_ROAR_ARRAY_MAX : Int = 4096

///|
/// Pure function: 64-bit ID decomposition into high 48-bit prefix and low 16-bit key.
#proof_pure
pub fn roaring_high_key(id : UInt64) -> UInt64 {
  id >> 16
}

///|
/// Pure function: Extracts low 16 bits of 64-bit ID.
#proof_pure
pub fn roaring_low_key(id : UInt64) -> Int {
  (id & 0xFFFFUL).to_int()
}

///|
/// Pure theorem: Reconstruction bijection: `(high << 16) | low == id`.
#proof_pure
pub fn roaring_reconstruct(high : UInt64, low : Int) -> UInt64 {
  (high << 16) | low.to_uint64()
}

///|
/// Decides container kind based on cardinal count.
#proof_pure
pub fn select_container_kind(count : Int) -> ContainerKind {
  if count < SPEC_ROAR_ARRAY_MAX {
    ContainerKind::ArrayContainer
  } else {
    ContainerKind::BitmapContainer
  }
}

///|
/// Checks membership in a sorted array of UInt64 using binary search.
pub fn sorted_array_contains(ids : Array[UInt64], target : UInt64) -> Bool {
  if ids.is_empty() {
    return false
  }
  let mut lo = 0
  let mut hi = ids.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let v = ids[mid]
    if v == target {
      return true
    } else if v < target {
      lo = mid + 1
    } else {
      if mid == 0 {
        break
      }
      hi = mid - 1
    }
  }
  false
}

///|
/// Checks membership in low 16-bit array using binary search.
pub fn array_container_contains(lows : Array[Int], target_low : Int) -> Bool {
  if lows.is_empty() {
    return false
  }
  let mut lo = 0
  let mut hi = lows.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let v = lows[mid]
    if v == target_low {
      return true
    } else if v < target_low {
      lo = mid + 1
    } else {
      if mid == 0 {
        break
      }
      hi = mid - 1
    }
  }
  false
}

///|
/// Tests bit in bitmap container (1024 64-bit words).
pub fn bitmap_container_test_bit(words : Array[UInt64], target_low : Int) -> Bool {
  if target_low < 0 || target_low >= 65536 || words.length() < 1024 {
    return false
  }
  let word_idx = target_low / 64
  let bit_idx = target_low % 64
  let mask = 1UL << bit_idx
  (words[word_idx] & mask) != 0UL
}

///|
/// Theorem: Roaring membership equivalence:
/// For encoded bytes `bs = encode_roaring(ids)` of a sorted unique ID array,
/// `roaring_contains(bs, query_id) == sorted_array_contains(ids, query_id)`.
pub fn verify_roaring_equivalence(
  ids : Array[UInt64],
  test_queries : Array[UInt64]
) -> Bool {
  let encoded = @format.encode_roaring(ids)
  let n = test_queries.length()
  for i in 0..<n {
    let q = test_queries[i]
    let expected = sorted_array_contains(ids, q)
    let actual = @format.roaring_contains(encoded, q)
    if expected != actual {
      return false
    }
  }
  true
}

///|
/// Theorem: Roaring decode round-trip preservation:
/// `decode_roaring(encode_roaring(ids)) == ids`.
pub fn verify_roaring_roundtrip(ids : Array[UInt64]) -> Bool {
  let encoded = @format.encode_roaring(ids)
  let decoded = @format.decode_roaring(encoded) catch {
    _ => return false
  }
  if decoded.length() != ids.length() {
    return false
  }
  let n = ids.length()
  for i in 0..<n {
    if decoded[i] != ids[i] {
      return false
    }
  }
  true
}
