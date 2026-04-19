/**
 * copycat Node.js FFI example (using koffi)
 *
 * Demonstrates loading libcopycat via koffi to list, read, and write
 * clipboard formats from Node.js — no shelling out to the CLI.
 *
 * Setup:
 *   zig build                              # build the shared library
 *   npm install koffi                      # install koffi (no C compiler needed)
 *   node examples/node-ffi.mjs             # run this example
 */

import koffi from "koffi";
import { platform } from "os";
import { join } from "path";

const ext = { darwin: "dylib", linux: "so", win32: "dll" }[platform()];
const libPath = join(import.meta.dirname, "..", "zig-out", ext === "dll" ? "bin" : "lib", `libcopycat.${ext}`);

const lib = koffi.load(libPath);

// Bind functions
const clipboard_list_formats = lib.func("clipboard_list_formats", "str", []);
const clipboard_read_format_ex = lib.func("clipboard_read_format_ex", "void", [
  "str",            // format
  koffi.out(koffi.pointer("void", 2)),  // out_data (pointer to pointer)
  koffi.out(koffi.pointer("uint64")),   // out_len
  koffi.out(koffi.pointer("int32")),    // out_status
]);
const clipboard_write_format = lib.func("clipboard_write_format", "int32", [
  "str",            // format
  "const void *",   // data
  "uint64",         // len
]);
const clipboard_clear = lib.func("clipboard_clear", "int32", []);
const clipboard_change_count = lib.func("clipboard_change_count", "int64", []);
const clipboard_free = lib.func("clipboard_free", "void", ["void *"]);

// --- Helper functions ---

function listFormats() {
  const json = clipboard_list_formats();
  return json ? JSON.parse(json) : [];
}

function readFormat(format) {
  const outData = [null];
  const outLen = [0n];
  const outStatus = [0];

  clipboard_read_format_ex(format, outData, outLen, outStatus);

  if (outStatus[0] !== 0) return null;
  const len = Number(outLen[0]);
  if (len === 0) return Buffer.alloc(0);

  const buf = Buffer.from(koffi.decode(outData[0], koffi.array("uint8", len)));
  clipboard_free(outData[0]);
  return buf;
}

function writeFormat(format, data) {
  const buf = typeof data === "string" ? Buffer.from(data) : data;
  return clipboard_write_format(format, buf, buf.length) === 0;
}

// --- Demo ---

console.log("=== copycat Node.js FFI Demo ===\n");

// 1. Show current clipboard state
const formats = listFormats();
console.log(`Clipboard has ${formats.length} format(s):`);
for (const f of formats) {
  const data = readFormat(f);
  console.log(`  ${f}  (${data?.length ?? 0} bytes)`);
}

console.log(`\nChange count: ${clipboard_change_count()}`);

// 2. Read plain text if available
const text = readFormat("public.utf8-plain-text");
if (text) {
  const preview = text.toString().slice(0, 100);
  console.log(`\nCurrent text: "${preview}${text.length > 100 ? "..." : ""}"`);
}

// 3. Write something new
const message = `Hello from Node.js FFI! (${new Date().toLocaleTimeString()})`;
if (writeFormat("public.utf8-plain-text", message)) {
  console.log(`\nWrote: "${message}"`);
  console.log(`Readback: "${readFormat("public.utf8-plain-text")?.toString()}"`);
  console.log(`New change count: ${clipboard_change_count()}`);
} else {
  console.error("\nFailed to write to clipboard");
}
