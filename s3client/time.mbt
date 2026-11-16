// SigV4 需要 amz_date（`YYYYMMDDTHHMMSSZ`，UTC），本项目只用系统时钟换算，
// 不引入任何 C stub：@env.now() 给出 epoch 毫秒，这里做纯 MoonBit 的
// “epoch days → 公历” 换算（Howard Hinnant 的 civil_from_days 算法）。

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : Int) -> String {
  if n < 10 {
    "000" + n.to_string()
  } else if n < 100 {
    "00" + n.to_string()
  } else if n < 1000 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// epoch 毫秒 → SigV4 的 amz_date（UTC，形如 20240102T030405Z）。
pub fn amz_date_from_unix_ms(ms : UInt64) -> String {
  let secs = (ms / 1000UL).reinterpret_as_int64()
  let days = secs / 86400L
  let sod = (secs % 86400L).to_int()
  let hour = sod / 3600
  let minute = (sod % 3600) / 60
  let second = sod % 60
  // civil_from_days
  let z = days + 719468L
  let era = if z >= 0L { z / 146097L } else { (z - 146096L) / 146097L }
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let mut y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = (doy - (153L * mp + 2L) / 5L + 1L).to_int()
  let m = (mp + (if mp < 10L { 3L } else { -9L })).to_int()
  if m <= 2 {
    y = y + 1L
  }
  let year = y.to_int()
  let b = StringBuilder()
  b.write_string(pad4(year))
  b.write_string(pad2(m))
  b.write_string(pad2(d))
  b.write_char('T')
  b.write_string(pad2(hour))
  b.write_string(pad2(minute))
  b.write_string(pad2(second))
  b.write_char('Z')
  b.to_string()
}

///|
/// 默认时钟：系统 UTC 当前时间
pub fn default_amz_date() -> String {
  amz_date_from_unix_ms(@env.now())
}
