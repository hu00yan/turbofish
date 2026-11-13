// store/budget.mbt: Shift-Left I/O & Compute Budget Assertion Framework
//
// 核心目标：在本地单元测试和模拟层中前移（Shift-Left）I/O 预算校验，
// 确保任何读、写、列举、探针操作严格遵守设计契约，杜绝静默网络请求放大。

///|
/// I/O 预算配置：定义各项存储操作与传输字节数的硬门槛。
/// 负数（如 -1 或 -1L）表示该指标不设限制（无上限）。
#derive(Debug, Eq)
pub(all) struct IoBudget {
  max_gets : Int
  max_puts : Int
  max_lists : Int
  max_deletes : Int
  max_head_gets : Int
  max_bytes_read : Int64
  max_bytes_written : Int64
}

///|
/// 创建自定义 I/O 预算。缺省值为 -1（无限制）。
pub fn IoBudget::new(
  max_gets~ : Int = -1,
  max_puts~ : Int = -1,
  max_lists~ : Int = -1,
  max_deletes~ : Int = -1,
  max_head_gets~ : Int = -1,
  max_bytes_read~ : Int64 = -1L,
  max_bytes_written~ : Int64 = -1L,
) -> IoBudget {
  {
    max_gets,
    max_puts,
    max_lists,
    max_deletes,
    max_head_gets,
    max_bytes_read,
    max_bytes_written,
  }
}

///|
/// 无限制预算（所有指标均无上限）。
pub fn IoBudget::unlimited() -> IoBudget {
  IoBudget::new()
}

///|
/// 零 I/O 预算：断言操作完全命中本地内存缓存，严禁任何底层存储交互。
pub fn IoBudget::zero() -> IoBudget {
  {
    max_gets: 0,
    max_puts: 0,
    max_lists: 0,
    max_deletes: 0,
    max_head_gets: 0,
    max_bytes_read: 0L,
    max_bytes_written: 0L,
  }
}

///|
/// 预设预算：点查读（最多 1 次 GET，最多 64KB 读取字节）。
pub fn IoBudget::point_read() -> IoBudget {
  {
    max_gets: 1,
    max_puts: 0,
    max_lists: 0,
    max_deletes: 0,
    max_head_gets: 0,
    max_bytes_read: 65536L, // 64KB
    max_bytes_written: 0L,
  }
}

///|
/// 预设预算：Head 指针探针（最多 1 次 GET，最多 1KB 读取字节）。
pub fn IoBudget::head_probe() -> IoBudget {
  {
    max_gets: 1,
    max_puts: 0,
    max_lists: 0,
    max_deletes: 0,
    max_head_gets: 1,
    max_bytes_read: 1024L, // 1KB
    max_bytes_written: 0L,
  }
}

///|
/// 预设预算：单个 Slab 读取（最多 1 次 GET，无字节上限）。
pub fn IoBudget::single_slab_read() -> IoBudget {
  {
    max_gets: 1,
    max_puts: 0,
    max_lists: 0,
    max_deletes: 0,
    max_head_gets: 0,
    max_bytes_read: -1L,
    max_bytes_written: 0L,
  }
}

///|
/// 预设预算：批写入（针对 n_parts 个数据分区提供确定性的 PUT 与写字节数上界）。
/// 包含每个分区的 PUT 以及发布元数据（manifest + head_ptr CAS）。
pub fn IoBudget::write_batch(
  n_parts : Int,
  max_bytes_per_part~ : Int64 = 10485760L,
) -> IoBudget {
  let parts = if n_parts < 0 { 0 } else { n_parts }
  {
    max_gets: 2, // 允许读取旧 manifest 与 head 指针
    max_puts: parts + 2, // 分区数据 + 1 manifest + 1 head pointer
    max_lists: 0,
    max_deletes: 0,
    max_head_gets: 2,
    max_bytes_read: 65536L, // 64KB 读预算
    max_bytes_written: parts.to_int64() * max_bytes_per_part + 65536L,
  }
}

///|
/// 链式修改 max_gets。
pub fn IoBudget::with_max_gets(self : IoBudget, gets : Int) -> IoBudget {
  { ..self, max_gets: gets }
}

///|
/// 链式修改 max_puts。
pub fn IoBudget::with_max_puts(self : IoBudget, puts : Int) -> IoBudget {
  { ..self, max_puts: puts }
}

///|
/// 链式修改 max_lists。
pub fn IoBudget::with_max_lists(self : IoBudget, lists : Int) -> IoBudget {
  { ..self, max_lists: lists }
}

///|
/// 链式修改 max_deletes。
pub fn IoBudget::with_max_deletes(self : IoBudget, deletes : Int) -> IoBudget {
  { ..self, max_deletes: deletes }
}

///|
/// 链式修改 max_head_gets。
pub fn IoBudget::with_max_head_gets(self : IoBudget, head_gets : Int) -> IoBudget {
  { ..self, max_head_gets: head_gets }
}

///|
/// 链式修改 max_bytes_read。
pub fn IoBudget::with_max_bytes_read(self : IoBudget, bytes : Int64) -> IoBudget {
  { ..self, max_bytes_read: bytes }
}

///|
/// 链式修改 max_bytes_written。
pub fn IoBudget::with_max_bytes_written(self : IoBudget, bytes : Int64) -> IoBudget {
  { ..self, max_bytes_written: bytes }
}

///|
/// 检验 tracker 当前指标是否超出 budget，返回违背项描述列表。
pub fn IoBudget::check(self : IoBudget, tracker : BudgetTracker) -> Array[String] {
  let violations : Array[String] = []
  if self.max_gets >= 0 && tracker.gets > self.max_gets {
    violations.push(
      "I/O Budget Exceeded: gets limit=\{self.max_gets}, actual=\{tracker.gets}",
    )
  }
  if self.max_puts >= 0 && tracker.puts > self.max_puts {
    violations.push(
      "I/O Budget Exceeded: puts limit=\{self.max_puts}, actual=\{tracker.puts}",
    )
  }
  if self.max_lists >= 0 && tracker.lists > self.max_lists {
    violations.push(
      "I/O Budget Exceeded: lists limit=\{self.max_lists}, actual=\{tracker.lists}",
    )
  }
  if self.max_deletes >= 0 && tracker.deletes > self.max_deletes {
    violations.push(
      "I/O Budget Exceeded: deletes limit=\{self.max_deletes}, actual=\{tracker.deletes}",
    )
  }
  if self.max_head_gets >= 0 && tracker.head_gets > self.max_head_gets {
    violations.push(
      "I/O Budget Exceeded: head_gets limit=\{self.max_head_gets}, actual=\{tracker.head_gets}",
    )
  }
  if self.max_bytes_read >= 0L && tracker.bytes_read > self.max_bytes_read {
    violations.push(
      "I/O Budget Exceeded: bytes_read limit=\{self.max_bytes_read}, actual=\{tracker.bytes_read}",
    )
  }
  if self.max_bytes_written >= 0L && tracker.bytes_written > self.max_bytes_written {
    violations.push(
      "I/O Budget Exceeded: bytes_written limit=\{self.max_bytes_written}, actual=\{tracker.bytes_written}",
    )
  }
  violations
}

///|
/// 判断当前 tracker 是否已超标。
pub fn IoBudget::is_exceeded(self : IoBudget, tracker : BudgetTracker) -> Bool {
  (self.max_gets >= 0 && tracker.gets > self.max_gets) ||
  (self.max_puts >= 0 && tracker.puts > self.max_puts) ||
  (self.max_lists >= 0 && tracker.lists > self.max_lists) ||
  (self.max_deletes >= 0 && tracker.deletes > self.max_deletes) ||
  (self.max_head_gets >= 0 && tracker.head_gets > self.max_head_gets) ||
  (self.max_bytes_read >= 0L && tracker.bytes_read > self.max_bytes_read) ||
  (self.max_bytes_written >= 0L && tracker.bytes_written > self.max_bytes_written)
}

///|
/// 格式化预算为易读字符串。
pub fn IoBudget::to_string(self : IoBudget) -> String {
  let gets_str = if self.max_gets < 0 { "unlimited" } else { self.max_gets.to_string() }
  let puts_str = if self.max_puts < 0 { "unlimited" } else { self.max_puts.to_string() }
  let lists_str = if self.max_lists < 0 { "unlimited" } else { self.max_lists.to_string() }
  let deletes_str = if self.max_deletes < 0 { "unlimited" } else { self.max_deletes.to_string() }
  let head_str = if self.max_head_gets < 0 { "unlimited" } else { self.max_head_gets.to_string() }
  let rbytes_str = if self.max_bytes_read < 0L { "unlimited" } else { self.max_bytes_read.to_string() }
  let wbytes_str = if self.max_bytes_written < 0L { "unlimited" } else { self.max_bytes_written.to_string() }
  "IoBudget(gets=\{gets_str}, puts=\{puts_str}, lists=\{lists_str}, deletes=\{deletes_str}, head_gets=\{head_str}, bytes_read=\{rbytes_str}, bytes_written=\{wbytes_str})"
}

///|
/// Budget 命名空间辅助类，提供标准预设。
pub struct Budget {}

///|
/// 创建 Budget 实例。
pub fn Budget::new() -> Budget {
  Budget::{}
}

///|
/// 预设：点查读（max 1 get, max 64KB bytes_read）。
pub fn Budget::point_read() -> IoBudget {
  IoBudget::point_read()
}

///|
/// 预设：Head 指针探针（max 1 get, max 1KB bytes_read）。
pub fn Budget::head_probe() -> IoBudget {
  IoBudget::head_probe()
}

///|
/// 预设：单个 Slab 读取（max 1 get）。
pub fn Budget::single_slab_read() -> IoBudget {
  IoBudget::single_slab_read()
}

///|
/// 预设：批写入（针对 n_parts 分区提供确定性 PUT / 字节界限）。
pub fn Budget::write_batch(
  n_parts : Int,
  max_bytes_per_part~ : Int64 = 10485760L,
) -> IoBudget {
  IoBudget::write_batch(n_parts, max_bytes_per_part~)
}

///|
/// 零 I/O 预算。
pub fn Budget::zero() -> IoBudget {
  IoBudget::zero()
}

///|
/// 无限制预算。
pub fn Budget::unlimited() -> IoBudget {
  IoBudget::unlimited()
}

///|
/// 自定义预算。
pub fn Budget::custom(
  max_gets~ : Int = -1,
  max_puts~ : Int = -1,
  max_lists~ : Int = -1,
  max_deletes~ : Int = -1,
  max_head_gets~ : Int = -1,
  max_bytes_read~ : Int64 = -1L,
  max_bytes_written~ : Int64 = -1L,
) -> IoBudget {
  IoBudget::new(
    max_gets~,
    max_puts~,
    max_lists~,
    max_deletes~,
    max_head_gets~,
    max_bytes_read~,
    max_bytes_written~,
  )
}

///|
/// 实时 I/O 操作与传输流量追踪器
#derive(Debug, Eq)
pub(all) struct BudgetTracker {
  mut gets : Int
  mut puts : Int
  mut lists : Int
  mut deletes : Int
  mut head_gets : Int
  mut bytes_read : Int64
  mut bytes_written : Int64
  violations : Array[String]
}

///|
/// 创建初始计数为 0 的追踪器。
pub fn BudgetTracker::new() -> BudgetTracker {
  {
    gets: 0,
    puts: 0,
    lists: 0,
    deletes: 0,
    head_gets: 0,
    bytes_read: 0L,
    bytes_written: 0L,
    violations: [],
  }
}

///|
/// 重置所有计数与违背记录。
pub fn BudgetTracker::reset(self : BudgetTracker) -> Unit {
  self.gets = 0
  self.puts = 0
  self.lists = 0
  self.deletes = 0
  self.head_gets = 0
  self.bytes_read = 0L
  self.bytes_written = 0L
  self.violations.clear()
}

///|
/// 记录 1 次 GET 请求及读取字节数。
pub fn BudgetTracker::record_get(self : BudgetTracker, bytes : Int) -> Unit {
  self.gets += 1
  if bytes > 0 {
    self.bytes_read += bytes.to_int64()
  }
}

///|
/// 记录读取字节增量。
pub fn BudgetTracker::record_read_bytes(self : BudgetTracker, bytes : Int) -> Unit {
  if bytes > 0 {
    self.bytes_read += bytes.to_int64()
  }
}

///|
/// 记录 1 次 PUT 请求及写入字节数。
pub fn BudgetTracker::record_put(self : BudgetTracker, bytes : Int) -> Unit {
  self.puts += 1
  if bytes > 0 {
    self.bytes_written += bytes.to_int64()
  }
}

///|
/// 记录 1 次 LIST 请求。
pub fn BudgetTracker::record_list(self : BudgetTracker) -> Unit {
  self.lists += 1
}

///|
/// 记录 1 次 DELETE 请求。
pub fn BudgetTracker::record_delete(self : BudgetTracker) -> Unit {
  self.deletes += 1
}

///|
/// 记录 1 次 HEAD GET 请求。
pub fn BudgetTracker::record_head(self : BudgetTracker) -> Unit {
  self.head_gets += 1
}

///|
/// 记录一次超预算违背。
pub fn BudgetTracker::record_violation(self : BudgetTracker, msg : String) -> Unit {
  self.violations.push(msg)
}

///|
/// 是否存在违背记录。
pub fn BudgetTracker::has_violations(self : BudgetTracker) -> Bool {
  self.violations.length() > 0
}

///|
/// 获取全部违背信息。
pub fn BudgetTracker::violations(self : BudgetTracker) -> Array[String] {
  self.violations
}

///|
/// 总请求数。
pub fn BudgetTracker::total_requests(self : BudgetTracker) -> Int {
  self.gets + self.puts + self.lists + self.deletes + self.head_gets
}

///|
/// 总传输字节数。
pub fn BudgetTracker::total_bytes(self : BudgetTracker) -> Int64 {
  self.bytes_read + self.bytes_written
}

///|
/// 拷贝当前统计快照。
pub fn BudgetTracker::clone(self : BudgetTracker) -> BudgetTracker {
  let vs : Array[String] = []
  for v in self.violations {
    vs.push(v)
  }
  {
    gets: self.gets,
    puts: self.puts,
    lists: self.lists,
    deletes: self.deletes,
    head_gets: self.head_gets,
    bytes_read: self.bytes_read,
    bytes_written: self.bytes_written,
    violations: vs,
  }
}

///|
/// 格式化追踪数据。
pub fn BudgetTracker::to_string(self : BudgetTracker) -> String {
  "BudgetTracker(gets=\{self.gets}, puts=\{self.puts}, lists=\{self.lists}, deletes=\{self.deletes}, head_gets=\{self.head_gets}, bytes_read=\{self.bytes_read}, bytes_written=\{self.bytes_written}, violations=\{self.violations.length()})"
}

///|
/// BudgetStore：透明包装任意 ObjectStore，按 IoBudget 实时拦截与统计。
pub struct BudgetStore[S] {
  store : S
  mut budget : IoBudget
  tracker : BudgetTracker
  strict : Bool
}

///|
/// 创建 BudgetStore 包装实例。
pub fn[S] BudgetStore::new(
  store : S,
  budget : IoBudget,
  strict~ : Bool = false,
) -> BudgetStore[S] {
  {
    store,
    budget,
    tracker: BudgetTracker::new(),
    strict,
  }
}

///|
/// 创建严格模式的 BudgetStore。
pub fn[S] BudgetStore::strict(store : S, budget : IoBudget) -> BudgetStore[S] {
  BudgetStore::new(store, budget, strict=true)
}

///|
/// 创建记录模式的 BudgetStore。
pub fn[S] BudgetStore::recording(store : S, budget : IoBudget) -> BudgetStore[S] {
  BudgetStore::new(store, budget, strict=false)
}

///|
/// 获取被包装的底层存储。
pub fn[S] BudgetStore::inner(self : BudgetStore[S]) -> S {
  self.store
}

///|
/// 获取当前预算配置。
pub fn[S] BudgetStore::budget(self : BudgetStore[S]) -> IoBudget {
  self.budget
}

///|
/// 动态切换预算配置。
pub fn[S] BudgetStore::set_budget(self : BudgetStore[S], budget : IoBudget) -> Unit {
  self.budget = budget
}

///|
/// 获取追踪器。
pub fn[S] BudgetStore::tracker(self : BudgetStore[S]) -> BudgetTracker {
  self.tracker
}

///|
/// 重置追踪器统计与违背记录。
pub fn[S] BudgetStore::reset(self : BudgetStore[S]) -> Unit {
  self.tracker.reset()
}

///|
/// 检查是否有预算违背。
pub fn[S] BudgetStore::has_violations(self : BudgetStore[S]) -> Bool {
  self.tracker.has_violations()
}

///|
/// 获取违背信息列表。
pub fn[S] BudgetStore::violations(self : BudgetStore[S]) -> Array[String] {
  self.tracker.violations()
}

///|
/// 获取最后一条违背信息。
pub fn[S] BudgetStore::last_violation(self : BudgetStore[S]) -> String? {
  if self.tracker.violations.length() == 0 {
    None
  } else {
    Some(self.tracker.violations[self.tracker.violations.length() - 1])
  }
}

///|
/// 断言当前累计指标严格在预算内。若超出或存在违背，抛出 @core.Corrupt 异常。
pub fn[S] BudgetStore::assert_within_budget(
  self : BudgetStore[S],
) -> Unit raise @core.SpndError {
  let vs = self.budget.check(self.tracker)
  if vs.length() > 0 {
    let mut msg = vs[0]
    for i in 1..<vs.length() {
      msg = msg + "; " + vs[i]
    }
    raise @core.Corrupt(msg)
  }
  if self.tracker.has_violations() {
    let msg = self.tracker.violations()[0]
    raise @core.Corrupt(msg)
  }
}

///|
/// 校验当前预算（同 assert_within_budget）。
pub fn[S] BudgetStore::check_budget(
  self : BudgetStore[S],
) -> Unit raise @core.SpndError {
  self.assert_within_budget()
}

///|
/// 断言 BudgetTracker 处于预算内。若超出预算则抛出 @core.Corrupt。
pub fn assert_within_budget(
  tracker : BudgetTracker,
  budget : IoBudget,
) -> Unit raise @core.SpndError {
  let vs = budget.check(tracker)
  if vs.length() > 0 {
    let mut msg = vs[0]
    for i in 1..<vs.length() {
      msg = msg + "; " + vs[i]
    }
    raise @core.Corrupt(msg)
  }
  if tracker.has_violations() {
    let msg = tracker.violations()[0]
    raise @core.Corrupt(msg)
  }
}

///|
/// 断言无任何违背。
pub fn assert_no_budget_violations(
  tracker : BudgetTracker,
) -> Unit raise @core.SpndError {
  if tracker.has_violations() {
    let msg = tracker.violations()[0]
    raise @core.Corrupt(msg)
  }
}

///|
/// 断言违背次数达到预期。
pub fn assert_budget_violations(
  tracker : BudgetTracker,
  expected_count : Int,
) -> Unit raise @core.SpndError {
  if tracker.violations.length() != expected_count {
    raise @core.Corrupt(
      "Expected \{expected_count} budget violations, found \{tracker.violations.length()}",
    )
  }
}

///|
/// 在指定预算作用域内执行动作，执行完毕后立即断言不超预算，并恢复原预算。
pub fn[S, T] with_budget(
  store : BudgetStore[S],
  budget : IoBudget,
  action : () -> T raise Error,
) -> T raise Error {
  let prev_budget = store.budget
  store.set_budget(budget)
  store.reset()
  let result = action()
  store.assert_within_budget()
  store.set_budget(prev_budget)
  result
}

///|
/// 便捷包装底层存储并在临时预算下执行。
pub fn[S, T] run_with_budget(
  store : S,
  budget : IoBudget,
  action : (BudgetStore[S]) -> T raise Error,
) -> T raise Error {
  let bstore = BudgetStore::new(store, budget)
  let result = action(bstore)
  bstore.assert_within_budget()
  result
}

///|
/// 实现 ObjectStore trait
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn get(
  self : BudgetStore[S],
  key : String,
) -> Bytes? {
  self.tracker.record_get(0)
  if self.budget.max_gets >= 0 && self.tracker.gets > self.budget.max_gets {
    self.tracker.record_violation(
      "I/O Budget Exceeded: gets limit=\{self.budget.max_gets}, actual=\{self.tracker.gets}",
    )
  }
  let res = self.store.get(key)
  match res {
    Some(bs) => {
      self.tracker.record_read_bytes(bs.length())
      if self.budget.max_bytes_read >= 0L &&
        self.tracker.bytes_read > self.budget.max_bytes_read {
        self.tracker.record_violation(
          "I/O Budget Exceeded: bytes_read limit=\{self.budget.max_bytes_read}, actual=\{self.tracker.bytes_read}",
        )
      }
    }
    None => ()
  }
  res
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn put(
  self : BudgetStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  self.tracker.record_put(value.length())
  if self.budget.max_puts >= 0 && self.tracker.puts > self.budget.max_puts {
    self.tracker.record_violation(
      "I/O Budget Exceeded: puts limit=\{self.budget.max_puts}, actual=\{self.tracker.puts}",
    )
  }
  if self.budget.max_bytes_written >= 0L &&
    self.tracker.bytes_written > self.budget.max_bytes_written {
    self.tracker.record_violation(
      "I/O Budget Exceeded: bytes_written limit=\{self.budget.max_bytes_written}, actual=\{self.tracker.bytes_written}",
    )
  }
  self.store.put(key, value)
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn put_if_match(
  self : BudgetStore[S],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  self.tracker.record_put(value.length())
  if self.budget.max_puts >= 0 && self.tracker.puts > self.budget.max_puts {
    self.tracker.record_violation(
      "I/O Budget Exceeded: puts limit=\{self.budget.max_puts}, actual=\{self.tracker.puts}",
    )
  }
  if self.budget.max_bytes_written >= 0L &&
    self.tracker.bytes_written > self.budget.max_bytes_written {
    self.tracker.record_violation(
      "I/O Budget Exceeded: bytes_written limit=\{self.budget.max_bytes_written}, actual=\{self.tracker.bytes_written}",
    )
  }
  self.store.put_if_match(key, expected, value)
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn get_range(
  self : BudgetStore[S],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.tracker.record_get(0)
  if self.budget.max_gets >= 0 && self.tracker.gets > self.budget.max_gets {
    self.tracker.record_violation(
      "I/O Budget Exceeded: gets limit=\{self.budget.max_gets}, actual=\{self.tracker.gets}",
    )
  }
  let res = self.store.get_range(key, offset, len)
  match res {
    Some(bs) => {
      self.tracker.record_read_bytes(bs.length())
      if self.budget.max_bytes_read >= 0L &&
        self.tracker.bytes_read > self.budget.max_bytes_read {
        self.tracker.record_violation(
          "I/O Budget Exceeded: bytes_read limit=\{self.budget.max_bytes_read}, actual=\{self.tracker.bytes_read}",
        )
      }
    }
    None => ()
  }
  res
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn list(
  self : BudgetStore[S],
  prefix : String,
) -> Array[String] {
  self.tracker.record_list()
  if self.budget.max_lists >= 0 && self.tracker.lists > self.budget.max_lists {
    self.tracker.record_violation(
      "I/O Budget Exceeded: lists limit=\{self.budget.max_lists}, actual=\{self.tracker.lists}",
    )
  }
  self.store.list(prefix)
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn delete(
  self : BudgetStore[S],
  key : String,
) -> Unit {
  self.tracker.record_delete()
  if self.budget.max_deletes >= 0 && self.tracker.deletes > self.budget.max_deletes {
    self.tracker.record_violation(
      "I/O Budget Exceeded: deletes limit=\{self.budget.max_deletes}, actual=\{self.tracker.deletes}",
    )
  }
  self.store.delete(key)
}

///|
pub impl[S : ObjectStore] ObjectStore for BudgetStore[S] with fn head_version(
  self : BudgetStore[S],
  key : String,
) -> String? {
  self.tracker.record_head()
  if self.budget.max_head_gets >= 0 &&
    self.tracker.head_gets > self.budget.max_head_gets {
    self.tracker.record_violation(
      "I/O Budget Exceeded: head_gets limit=\{self.budget.max_head_gets}, actual=\{self.tracker.head_gets}",
    )
  }
  self.store.head_version(key)
}

///|
/// 实现 BatchStore trait
pub impl[S : ObjectStore] BatchStore for BudgetStore[S] with fn get_many(
  self : BudgetStore[S],
  keys : Array[String],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = []
  for k in keys {
    out.push(ObjectStore::get(self, k))
  }
  out
}

///|
pub impl[S : ObjectStore] BatchStore for BudgetStore[S] with fn get_range_many(
  self : BudgetStore[S],
  ranges : Array[(String, Int, Int)],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = []
  for r in ranges {
    out.push(ObjectStore::get_range(self, r.0, r.1, r.2))
  }
  out
}

///|
/// 显式方法导出（避免警告）
pub fn[S : ObjectStore] BudgetStore::get(
  self : BudgetStore[S],
  key : String,
) -> Bytes? {
  ObjectStore::get(self, key)
}

///|
pub fn[S : ObjectStore] BudgetStore::put(
  self : BudgetStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  ObjectStore::put(self, key, value)
}

///|
pub fn[S : ObjectStore] BudgetStore::put_if_match(
  self : BudgetStore[S],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  ObjectStore::put_if_match(self, key, expected, value)
}

///|
pub fn[S : ObjectStore] BudgetStore::get_range(
  self : BudgetStore[S],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  ObjectStore::get_range(self, key, offset, len)
}

///|
pub fn[S : ObjectStore] BudgetStore::list(
  self : BudgetStore[S],
  prefix : String,
) -> Array[String] {
  ObjectStore::list(self, prefix)
}

///|
pub fn[S : ObjectStore] BudgetStore::delete(
  self : BudgetStore[S],
  key : String,
) -> Unit {
  ObjectStore::delete(self, key)
}

///|
pub fn[S : ObjectStore] BudgetStore::head_version(
  self : BudgetStore[S],
  key : String,
) -> String? {
  ObjectStore::head_version(self, key)
}

///|
pub fn[S : ObjectStore] BudgetStore::get_many(
  self : BudgetStore[S],
  keys : Array[String],
) -> Array[Bytes?] {
  BatchStore::get_many(self, keys)
}

///|
pub fn[S : ObjectStore] BudgetStore::get_range_many(
  self : BudgetStore[S],
  ranges : Array[(String, Int, Int)],
) -> Array[Bytes?] {
  BatchStore::get_range_many(self, ranges)
}

///|
/// 带超标即时抛出的校验读取方法
pub fn[S : ObjectStore] BudgetStore::get_checked(
  self : BudgetStore[S],
  key : String,
) -> Bytes? raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  let res = ObjectStore::get(self, key)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
  res
}

///|
pub fn[S : ObjectStore] BudgetStore::put_checked(
  self : BudgetStore[S],
  key : String,
  value : Bytes,
) -> Unit raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  ObjectStore::put(self, key, value)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
}

///|
pub fn[S : ObjectStore] BudgetStore::put_if_match_checked(
  self : BudgetStore[S],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  let res = ObjectStore::put_if_match(self, key, expected, value)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
  res
}

///|
pub fn[S : ObjectStore] BudgetStore::get_range_checked(
  self : BudgetStore[S],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  let res = ObjectStore::get_range(self, key, offset, len)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
  res
}

///|
pub fn[S : ObjectStore] BudgetStore::list_checked(
  self : BudgetStore[S],
  prefix : String,
) -> Array[String] raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  let res = ObjectStore::list(self, prefix)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
  res
}

///|
pub fn[S : ObjectStore] BudgetStore::delete_checked(
  self : BudgetStore[S],
  key : String,
) -> Unit raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  ObjectStore::delete(self, key)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
}

///|
pub fn[S : ObjectStore] BudgetStore::head_version_checked(
  self : BudgetStore[S],
  key : String,
) -> String? raise @core.SpndError {
  let prev_violations = self.tracker.violations.length()
  let res = ObjectStore::head_version(self, key)
  if self.tracker.violations.length() > prev_violations {
    raise @core.Corrupt(self.tracker.violations[prev_violations])
  }
  res
}
