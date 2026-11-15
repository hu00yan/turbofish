// 计费：AWS S3 Standard 请求费（美元），费率表在 SimConfig.rates（BillRates）。
//
// 计费口径：
// - 只有真正打到 S3 的 GET 才计 GET 费（内存/NVMe 命中不计）；
// - put/put_if_match **每次尝试**都计 PUT 费（含 CAS 失败——真 S3 条件写失败也是一次请求）；
// - list 每页（本场景每次调用）一次 LIST 费；delete 一次 DELETE 费（S3 Standard 默认 0）；
// - egress 启用时按 S3 读出字节计出口费，单独记 bill_egress；bill_requests_total
//   仍是 get+put+list+delete 四项之和，bill_total 再叠加 egress。
// - 存储费（storage_per_gb_month）不走这里：storage_monthly_bill() 单独按当前总字节给。

///|
/// 一次真实 S3 GET 的费用；s3_bytes 为本次从 S3 读出的字节数（0 表示 miss/404）。
fn SimStore::charge_get(self : SimStore, s3_bytes : Int) -> Unit {
  let _ = s3_bytes
  self.bill_get += self.cfg.rates.get_per_1k / 1000.0
}

///|
/// 一次 S3 读出的出口费（未启用 egress 时为 0）。
fn SimStore::charge_egress(self : SimStore, s3_bytes : Int) -> Unit {
  if self.cfg.egress_enabled && s3_bytes > 0 {
    self.bill_egress += s3_bytes.to_double() /
      1073741824.0 *
      self.cfg.rates.egress_per_gb
  }
}

///|
/// 一次 PUT 尝试的费用（无论 CAS 成败）。
fn SimStore::charge_put(self : SimStore) -> Unit {
  self.bill_put += self.cfg.rates.put_per_1k / 1000.0
}

///|
/// 一次 LIST（一页）的费用。
fn SimStore::charge_list(self : SimStore) -> Unit {
  self.bill_list += self.cfg.rates.list_per_1k / 1000.0
}

///|
/// 一次 DELETE 的费用。
fn SimStore::charge_delete(self : SimStore) -> Unit {
  self.bill_delete += self.cfg.rates.delete_per_1k / 1000.0
}
