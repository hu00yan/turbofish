// store/budget_wbtest.mbt: Shift-Left I/O Budget White-Box Tests

test "IoBudget: presets and customization" {
  let p = Budget::point_read()
  assert_eq(p.max_gets, 1)
  assert_eq(p.max_puts, 0)
  assert_eq(p.max_bytes_read, 65536L)

  let h = Budget::head_probe()
  assert_eq(h.max_gets, 1)
  assert_eq(h.max_head_gets, 1)
  assert_eq(h.max_bytes_read, 1024L)

  let s = Budget::single_slab_read()
  assert_eq(s.max_gets, 1)
  assert_eq(s.max_bytes_read, -1L)

  let wb = Budget::write_batch(3)
  assert_eq(wb.max_puts, 5) // 3 + 2
  assert_eq(wb.max_gets, 2)
  assert_eq(wb.max_bytes_written, 3L * 10485760L + 65536L)

  let custom = Budget::unlimited()
    .with_max_gets(5)
    .with_max_puts(2)
    .with_max_lists(1)
    .with_max_deletes(0)
    .with_max_head_gets(3)
    .with_max_bytes_read(2048L)
    .with_max_bytes_written(4096L)
  assert_eq(custom.max_gets, 5)
  assert_eq(custom.max_puts, 2)
  assert_eq(custom.max_lists, 1)
  assert_eq(custom.max_deletes, 0)
  assert_eq(custom.max_head_gets, 3)
  assert_eq(custom.max_bytes_read, 2048L)
  assert_eq(custom.max_bytes_written, 4096L)
  assert_eq(custom.to_string().has_prefix("IoBudget("), true)
}

test "BudgetTracker: tracking, counting, reset, and clone" {
  let t = BudgetTracker::new()
  assert_eq(t.total_requests(), 0)
  assert_eq(t.total_bytes(), 0L)
  assert_eq(t.has_violations(), false)

  t.record_get(100)
  t.record_read_bytes(50)
  t.record_put(300)
  t.record_list()
  t.record_delete()
  t.record_head()

  assert_eq(t.gets, 1)
  assert_eq(t.bytes_read, 150L)
  assert_eq(t.puts, 1)
  assert_eq(t.bytes_written, 300L)
  assert_eq(t.lists, 1)
  assert_eq(t.deletes, 1)
  assert_eq(t.head_gets, 1)
  assert_eq(t.total_requests(), 5)
  assert_eq(t.total_bytes(), 450L)

  let c = t.clone()
  assert_eq(c.total_requests(), 5)
  assert_eq(c.total_bytes(), 450L)

  t.reset()
  assert_eq(t.total_requests(), 0)
  assert_eq(t.total_bytes(), 0L)
  assert_eq(t.has_violations(), false)
  // 克隆不受影响
  assert_eq(c.total_requests(), 5)
}

test "BudgetStore: pass-through correctness to MemStore" {
  let mem = MemStore::new()
  let bstore = BudgetStore::new(mem, Budget::unlimited())

  // put and get
  bstore.put("k1", b"hello world")
  let val = bstore.get("k1")
  assert_eq(val, Some(b"hello world"))
  assert_eq(bstore.inner().get("k1"), Some(b"hello world"))

  // put_if_match
  let cas1 = bstore.put_if_match("k2", None, b"cas initial")
  assert_eq(cas1, true)
  let ver = bstore.head_version("k2")
  assert_eq(ver, Some("v2"))

  let cas_fail = bstore.put_if_match("k2", Some("v999"), b"cas fail")
  assert_eq(cas_fail, false)

  let cas_ok = bstore.put_if_match("k2", Some("v2"), b"cas updated")
  assert_eq(cas_ok, true)
  assert_eq(bstore.get("k2"), Some(b"cas updated"))

  // get_range
  let range_val = bstore.get_range("k1", 0, 5)
  assert_eq(range_val, Some(b"hello"))

  // list
  let keys = bstore.list("k")
  assert_eq(keys, ["k1", "k2"])

  // delete
  bstore.delete("k1")
  assert_eq(bstore.get("k1"), None)
  assert_eq(bstore.inner().get("k1"), None)

  // BatchStore
  bstore.put("b1", b"val1")
  bstore.put("b2", b"val2")
  let many = bstore.get_many(["b1", "b2", "b3"])
  assert_eq(many.length(), 3)
  assert_eq(many[0], Some(b"val1"))
  assert_eq(many[1], Some(b"val2"))
  assert_eq(many[2], None)

  let range_many = bstore.get_range_many([("b1", 0, 3), ("b2", 1, 2)])
  assert_eq(range_many.length(), 2)
  assert_eq(range_many[0], Some(b"val"))
  assert_eq(range_many[1], Some(b"al"))

  // 无违背
  assert_eq(bstore.has_violations(), false)
  bstore.assert_within_budget() catch {
    _ => fail("unexpected budget violation in unlimited store")
  }
}

test "BudgetStore: point_read budget enforcement" {
  let mem = MemStore::new()
  mem.put("p1", b"short content")
  let bstore = BudgetStore::new(mem, Budget::point_read())

  // 第一次读取：合法
  let r1 = bstore.get("p1")
  assert_eq(r1, Some(b"short content"))
  assert_eq(bstore.has_violations(), false)
  bstore.assert_within_budget() catch {
    _ => fail("first point read should be within budget")
  }

  // 第二次读取：超出 max_gets (1)
  let r2 = bstore.get("p1")
  assert_eq(r2, Some(b"short content"))
  assert_eq(bstore.has_violations(), true)
  assert_eq(bstore.violations().length(), 1)
  assert_eq(
    bstore.violations()[0],
    "I/O Budget Exceeded: gets limit=1, actual=2",
  )

  // assert_within_budget 必须抛出 @core.Corrupt
  let mut caught = false
  try {
    bstore.assert_within_budget()
  } catch {
    @core.Corrupt(msg) => {
      caught = true
      assert_eq(msg.has_prefix("I/O Budget Exceeded: "), true)
    }
    _ => fail("expected @core.Corrupt error")
  }
  assert_eq(caught, true)
}

test "BudgetStore: point_read bytes limit exceeded" {
  let mem = MemStore::new()
  // 构造 70KB 大小数据（超出 point_read 的 64KB 上限）
  let big_data = Bytes::make(70 * 1024, b'x')
  mem.put("big", big_data)

  let bstore = BudgetStore::new(mem, Budget::point_read())
  let _ = bstore.get("big")

  assert_eq(bstore.has_violations(), true)
  let last = bstore.last_violation()
  match last {
    Some(msg) => assert_eq(msg.has_prefix("I/O Budget Exceeded: bytes_read"), true)
    None => fail("expected violation for bytes_read")
  }

  let mut caught = false
  try {
    bstore.assert_within_budget()
  } catch {
    @core.Corrupt(msg) => {
      caught = true
      assert_eq(msg.has_prefix("I/O Budget Exceeded: bytes_read"), true)
    }
    _ => fail("expected Corrupt")
  }
  assert_eq(caught, true)
}

test "BudgetStore: head_probe budget enforcement" {
  let mem = MemStore::new()
  mem.put("ns/_head_ptr", b"manifest-001")
  let bstore = BudgetStore::new(mem, Budget::head_probe())

  // 1 次 head probe
  let ptr = read_head_pointer(bstore, "ns")
  assert_eq(ptr, Some("manifest-001"))
  assert_eq(bstore.has_violations(), false)

  // 再次 head probe 超出 max_gets (1)
  let _ = read_head_pointer(bstore, "ns")
  assert_eq(bstore.has_violations(), true)

  let mut caught = false
  try {
    bstore.assert_within_budget()
  } catch {
    @core.Corrupt(msg) => {
      caught = true
      assert_eq(msg.has_prefix("I/O Budget Exceeded: gets"), true)
    }
    _ => fail("expected Corrupt")
  }
  assert_eq(caught, true)
}

test "BudgetStore: single_slab_read allows large single GET" {
  let mem = MemStore::new()
  let slab = Bytes::make(500 * 1024, b's') // 500KB
  mem.put("seg.slab", slab)

  let bstore = BudgetStore::new(mem, Budget::single_slab_read())
  let r = bstore.get("seg.slab")
  assert_eq(r.map(fn(b) { b.length() }), Some(500 * 1024))
  // 单个 slab 读无字节上限，因此 1 次 GET 合法通过
  assert_eq(bstore.has_violations(), false)

  // 第 2 次读超标
  let _ = bstore.get("seg.slab")
  assert_eq(bstore.has_violations(), true)
}

test "BudgetStore: write_batch deterministic put and byte bounds" {
  let mem = MemStore::new()
  let wb_budget = Budget::write_batch(2, max_bytes_per_part=1000L)
  let bstore = BudgetStore::new(mem, wb_budget)

  // 2 个分区 PUT + 1 manifest + 1 head_ptr = 4 PUTs
  bstore.put("part-1", Bytes::make(500, b'1'))
  bstore.put("part-2", Bytes::make(500, b'2'))
  bstore.put("manifest", Bytes::make(200, b'm'))
  bstore.put("head_ptr", Bytes::make(20, b'h'))

  assert_eq(bstore.has_violations(), false)
  bstore.assert_within_budget() catch {
    _ => fail("4 PUTs within write_batch(2) budget")
  }

  // 第 5 个 PUT 超出 max_puts (4)
  bstore.put("part-3", Bytes::make(100, b'3'))
  assert_eq(bstore.has_violations(), true)
  assert_eq(
    bstore.last_violation(),
    Some("I/O Budget Exceeded: puts limit=4, actual=5"),
  )
}

test "BudgetStore: checked methods raise @core.Corrupt immediately" {
  let mem = MemStore::new()
  let bstore = BudgetStore::new(mem, Budget::point_read())

  let _ = bstore.put_checked("key", b"test data") catch {
    @core.Corrupt(msg) => {
      // put_checked 超出 point_read 的 max_puts (0)
      assert_eq(msg.has_prefix("I/O Budget Exceeded: puts"), true)
      ()
    }
    _ => fail("expected Corrupt")
  }

  // 正常 put 进底座
  mem.put("key", b"test data")

  // 第 1 次 get_checked 合法
  let v1 = bstore.get_checked("key") catch {
    _ => fail("first get_checked should succeed")
  }
  assert_eq(v1, Some(b"test data"))

  // 第 2 次 get_checked 立即抛错
  let mut caught = false
  try {
    let _ = bstore.get_checked("key")
    fail("expected get_checked to fail")
  } catch {
    @core.Corrupt(msg) => {
      caught = true
      assert_eq(msg.has_prefix("I/O Budget Exceeded: gets"), true)
    }
    _ => fail("expected Corrupt")
  }
  assert_eq(caught, true)
}

test "with_budget: scope isolation and assertion" {
  let mem = MemStore::new()
  mem.put("k", b"val")
  let bstore = BudgetStore::new(mem, Budget::unlimited())

  // 作用域 1：在 point_read 预算下仅执行 1 次读
  let res = with_budget(bstore, Budget::point_read(), fn() {
    let v = bstore.get("k")
    assert_eq(v, Some(b"val"))
    123
  }) catch {
    _ => fail("within point_read budget should pass")
  }
  assert_eq(res, 123)
  // 原预算恢复
  assert_eq(bstore.budget().max_gets, -1)

  // 作用域 2：执行 2 次读超预算
  let mut caught = false
  try {
    with_budget(bstore, Budget::point_read(), fn() {
      let _ = bstore.get("k")
      let _ = bstore.get("k")
      ()
    })
  } catch {
    @core.Corrupt(msg) => {
      caught = true
      assert_eq(msg.has_prefix("I/O Budget Exceeded: gets"), true)
    }
    _ => fail("expected Corrupt")
  }
  assert_eq(caught, true)
}

test "run_with_budget: wrap and execute" {
  let mem = MemStore::new()
  mem.put("k", b"val")

  let out = run_with_budget(mem, Budget::point_read(), fn(bs) {
    let v = bs.get("k")
    assert_eq(v, Some(b"val"))
    "success"
  }) catch {
    _ => fail("run_with_budget should succeed")
  }
  assert_eq(out, "success")
}

test "Budget::zero: assert 0 I/O" {
  let mem = MemStore::new()
  let bstore = BudgetStore::new(mem, Budget::zero())

  // 无操作时断言通过
  bstore.assert_within_budget() catch {
    _ => fail("0 ops should pass Budget::zero")
  }

  // 任何 1 次读取即超预算
  let _ = bstore.get("anything")
  assert_eq(bstore.has_violations(), true)
  assert_eq(
    bstore.violations()[0],
    "I/O Budget Exceeded: gets limit=0, actual=1",
  )
}
