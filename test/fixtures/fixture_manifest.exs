# Fixture round-trip manifest — outcomes for every binary/JSON
# round-trip we run against our generated decoders.
#
# Regenerate with:
#
#     mix flatbuf.fixtures.update
#
# Corpus pinned to google/flatbuffers @ v25.12.19.

%{
  "alignment_test" =>
    {:error, :flatc,
     {:flatc_failed,
      "\nerror:\n  /tmp/flatbuf_oracle_3/input.json:2: 22: error: unknown field: small_structs\n\n"}},
  "annotated_binary" => :ok,
  "evolution_v1" => {:error, :flatc, {:flatc_no_json, ""}},
  "evolution_v2" => :ok,
  "monsterdata_cstest" => :ok,
  "monsterdata_cstest_sp" => :ok,
  "monsterdata_extra" => :ok,
  "monsterdata_javascript_wire" => :ok,
  "monsterdata_python_wire" => :ok,
  "monsterdata_swift" => :ok,
  "monsterdata_test" => :ok,
  "optional_scalars" => :ok,
  "optional_scalars_defaults" => :ok,
  "test_64bit" =>
    {:error, :flatc,
     {:flatc_no_json,
      "Usage: /home/lawik/sprawl/flatbuf/_build/test/flatc/flatc [-b|--binary,\n-c|--cpp, -n|--csharp, -d|--dart, -g|--go, -j|--java, -t|--json, --jsonschema,\n--kotlin, --kotlin-kmp, --lobster, -l|--lua, --nim, --php, --proto, -p|--python,\n-r|--rust, --swift, -T|--ts, -o, -I, -M, --version, -h|--help, --strict-json,\n--allow-non-utf8, --natural-utf8, --defaults-json, --unknown-json, --no-prefix,\n--scoped-enums, --no-emit-min-max-enum-values, --swift-implementation-only,\n--gen-includes, --no-includes, --gen-mutable, --gen-onefile, --gen-name-strings,\n--gen-object-api, --gen-compare, --gen-nullable, --java-package-prefix,\n--java-checkerframework, --gen-generated, --gen-jvmstatic, --gen-all,\n--gen-json-emit, --cpp-include, --cpp-ptr-type, --cpp-str-type,\n--cpp-str-flex-ctor, --cpp-field-case-style, --cpp-std, --cpp-static-reflection,\n--object-prefix, --object-suffix, --go-namespace, --go-import, --go-module-name,\n--raw-binary, --size-prefixed, --proto-namespace-suffix, --oneof-union,\n--keep-proto-id, --proto-id-gap, --grpc, --schema, --bfbs-filenames,\n--bfbs-absolute-paths, --bfbs-comments, --bfbs-builtins, --bfbs-gen-embed,\n--conform, --conform-includes, --filename-suffix, --filename-ext,\n--include-prefix, --keep-prefix, --reflect-types, --reflect-names,\n--rust-serialize, --rust-module-root-file, --root-type, --require-explicit-ids,\n--force-defaults, --force-empty, --force-empty-vectors, --flexbuffers,\n--no-warnings, --warnings-as-errors, --cs-global-alias,\n--cs-gen-json-serializer, --json-nested-bytes, --ts-flat-files,\n--ts-entry-points, --annotate-sparse-vectors, --annotate,\n--no-leak-private-annotation, --python-no-type-prefix-suffix, --python-typing,\n--python-version, --python-decode-obj-api-strings, --python-gen-numpy,\n--ts-omit-entrypoint, --file-names-only, --grpc-filename-suffix,\n--grpc-additional-header, --grpc-use-system-headers, --grpc-search-path,\n--grpc-python-typed-handlers, --grpc-callback-api]... FILE... [--\nBINARY_FILE...]\n\nerror:\n  Unable to generate text for input (unknown type)\n\n/home/lawik/sprawl/flatbuf/_build/test/flatc/flatc: "}},
  "unicode_test" => :ok,
  "unicode_test_ts" => :ok,
  "union_vector" => :ok
}
