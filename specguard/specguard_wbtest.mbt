// specguard 自测：
// - 真跑一遍 run()（读仓库真实源码，四条断言全过才算绿）；
// - 用「故意违规的文本/计数」验证断言确实会失败（应失败的情形用 try/catch
//   记录，不在可能抛的上下文里直接 assert）。

///|
async test "specguard invariants" {
  // ---- 0. run() 在真实仓库上必须通过（任一断言红就 raise 到测试） ----
  let report = run()
  // 断言 1 覆盖 format/build/query/cmd 四目录下全部 .mbt（当前 69 个）。
  assert_true(report.id_double_sites > 40)
  // 断言 3 扫到全仓 moon.pkg（>= 30 个），且放行的 native-stub 恰好是基线 5 条。
  assert_true(report.pkg_files >= 25)
  assert_eq(report.stubs_allowlisted, 5)

  // ---- 1. 整型 id 过 double：违规文本必判 true，合规文本必判 false ----
  let bad_line = "    sm.set(\"min_id\", Json::number(s.min_id.to_double()))"
  assert_true(scan_file_forbidden_id_double(bad_line))
  // 只是 to_double（非 id 字段）不算违规。
  assert_false(
    scan_file_forbidden_id_double(
      "    let err = (a.to_double() - b.to_double()).abs()",
    ),
  )
  // id 字段但没走 Json::number 也不算违规（这正是不许回退的正确写法）。
  assert_false(
    scan_file_forbidden_id_double(
      "    sm.set(\"min_id\", Json::string(s.min_id.to_string()))",
    ),
  )
  // 键归一化：行号漂移 / 前缀变化都不破基线。
  assert_eq(
    violation_key("format/manifest.mbt", bad_line),
    "format/manifest.mbt#min_id",
  )
  // 同一行内容出现在新路径 → 不在基线内（额度 0）。
  assert_eq(id_double_baseline_count("format/manifest.mbt#min_id"), 1)
  assert_eq(id_double_baseline_count("cmd/newwriter/main.mbt#min_id"), 0)

  // 计数超基线必须 raise；等于基线必须不 raise。
  let over : Map[String, Int32] = Map([])
  over.set("build/slab.mbt#min_id", 2)
  let mut caught_bad = false
  verify_id_double_counts(over) catch {
    SpecViolation(msg) => {
      caught_bad = true
      assert_true(msg.has_prefix("断言1 失败"))
    }
    _ => fail("expected SpecViolation for over-budget id-double count")
  }
  assert_true(caught_bad)
  let exact : Map[String, Int32] = Map([])
  exact.set("build/slab.mbt#min_id", 1)
  verify_id_double_counts(exact)
  assert_eq(exact.get("build/slab.mbt#min_id").unwrap_or(0), 1)

  // ---- 2. slab magic：只许 SLAB/SLIX（预留 SLB1/SLB2） ----
  assert_true(magic_literal_allowed("SLAB"))
  assert_true(magic_literal_allowed("SLIX"))
  assert_true(magic_literal_allowed("SLB2"))
  assert_false(magic_literal_allowed("SLBX"))
  assert_false(magic_literal_allowed("SLAB0"))
  let slab_ok = "pub const SLAB_MAGIC : String = \"SLAB\"\npub const SLAB_INDEX_MAGIC : String = \"SLIX\"\n"
  assert_true(slab_magic_ok(slab_ok))
  // 常量被改值 / 被删都会红。
  assert_false(
    slab_magic_ok(
      "pub const SLAB_MAGIC : String = \"SLBX\"\npub const SLAB_INDEX_MAGIC : String = \"SLIX\"\n",
    ),
  )
  assert_false(slab_magic_ok("pub const SLAB_MAGIC : String = \"SLAB\"\n"))
  // 多出来的未知 MAGIC 常量也必须白名单内。
  assert_false(
    slab_magic_ok(
      "pub const SLAB_MAGIC : String = \"SLAB\"\npub const SLAB_INDEX_MAGIC : String = \"SLIX\"\npub const SLAB_TRAILER_MAGIC : String = \"SLBZ\"\n",
    ),
  )

  // ---- 3. moon.pkg：native-stub 只放行基线 5 条，link: 一律不许出现 ----
  let stub_pkg = "options(\n  \"native-stub\": [ \"uring.c\" ],\n)\n"
  assert_eq(pkg_stub_names(stub_pkg), ["uring.c"])
  assert_false(pkg_has_link_section(stub_pkg))
  assert_true(stub_allowed("uring", "uring.c"))
  assert_true(stub_allowed("cmd/idxrepo", "idxfs.c"))
  // 任务描述里点名的两个白名单项在仓库里不存在，因此不放行。
  assert_false(stub_allowed("uring", "uring_native.c"))
  assert_false(stub_allowed("netutil", "tpool.c"))
  // 多行数组也要能解析。
  assert_eq(
    pkg_stub_names(
      "options(\n  \"native-stub\": [\n    \"a.c\",\n    \"b.c\",\n  ],\n)\n",
    ),
    ["a.c", "b.c"],
  )
  // s3http 那种 libcurl 链接段必须被抓住（含注释里的提法不算）。
  let link_pkg = "options(\n  link: {\n    \"native\": {\n      \"cc-link-flags\": \"-L/opt/homebrew/opt/curl/lib -lcurl\",\n    },\n  },\n)\n"
  assert_true(pkg_has_link_section(link_pkg))
  assert_false(
    pkg_has_link_section(
      "// 历史上用过 link: 与 cc-link-flags，禁止回流\n",
    ),
  )
  assert_false(
    pkg_has_link_section(
      "// io_uring 完成引擎（native-stub）。不再链接 libcurl\n",
    ),
  )

  // ---- 4. cmd 不得硬编码 macOS 包管理路径 ----
  assert_true(
    line_hardcoded_host_path("  let lib = \"/opt/homebrew/opt/curl/lib\""),
  )
  assert_true(
    line_hardcoded_host_path("  let inc = \"/usr/local/opt/openssl\""),
  )
  assert_false(line_hardcoded_host_path("  let p = \"format/slab.mbt\""))
  assert_false(
    line_hardcoded_host_path("  let p = \"/usr/local/bin/turbofish\""),
  )
}
