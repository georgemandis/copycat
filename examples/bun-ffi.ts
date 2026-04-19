/**
 * copycat Bun FFI example
 *
 * Demonstrates loading libcopycat via Bun's FFI to list, read, and write
 * clipboard formats programmatically — no shelling out to the CLI.
 *
 * Usage:
 *   zig build                          # build the shared library
 *   bun run examples/bun-ffi.ts        # run this example
 */

import { dlopen, FFIType, suffix, ptr, toBuffer, CString } from "bun:ffi";

const lib = dlopen(`./zig-out/lib/libcopycat.${suffix}`, {
  clipboard_list_formats: {
    args: [],
    returns: FFIType.ptr,
  },
  clipboard_read_format_ex: {
    args: [FFIType.cstring, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.void,
  },
  clipboard_write_format: {
    args: [FFIType.cstring, FFIType.ptr, FFIType.u64],
    returns: FFIType.i32,
  },
  clipboard_clear: {
    args: [],
    returns: FFIType.i32,
  },
  clipboard_change_count: {
    args: [],
    returns: FFIType.i64,
  },
  clipboard_free: {
    args: [FFIType.ptr],
    returns: FFIType.void,
  },
});

const { symbols: clip } = lib;

// --- Helper functions ---

function listFormats(): string[] {
  const rawPtr = clip.clipboard_list_formats();
  if (!rawPtr) return [];
  const json = new CString(rawPtr);
  const formats = JSON.parse(json.toString());
  clip.clipboard_free(rawPtr);
  return formats;
}

function readFormat(format: string): Buffer | null {
  const outData = new BigInt64Array(1);
  const outLen = new BigInt64Array(1);
  const outStatus = new Int32Array(1);

  clip.clipboard_read_format_ex(
    Buffer.from(format + "\0"),
    ptr(outData),
    ptr(outLen),
    ptr(outStatus),
  );

  if (outStatus[0] !== 0) return null;
  const len = Number(outLen[0]);
  if (len === 0) return Buffer.alloc(0);

  const dataPtr = Number(outData[0]);
  const buf = Buffer.from(toBuffer(dataPtr, 0, len));
  clip.clipboard_free(dataPtr);
  return buf;
}

function writeFormat(format: string, data: string | Buffer): boolean {
  const buf = typeof data === "string" ? Buffer.from(data) : data;
  return (
    clip.clipboard_write_format(
      Buffer.from(format + "\0"),
      buf.length > 0 ? ptr(buf) : 0,
      buf.length,
    ) === 0
  );
}

// --- Demo ---

console.log("=== copycat Bun FFI Demo ===\n");

// 1. Show current clipboard state
const formats = listFormats();
console.log(`Clipboard has ${formats.length} format(s):`);
for (const f of formats) {
  const data = readFormat(f);
  console.log(`  ${f}  (${data?.length ?? 0} bytes)`);
}

console.log(`\nChange count: ${Number(clip.clipboard_change_count())}`);

// 2. Read plain text if available
const text = readFormat("public.utf8-plain-text");
if (text) {
  const preview = text.toString().slice(0, 100);
  console.log(`\nCurrent text: "${preview}${text.length > 100 ? "..." : ""}"`);
}

// 3. Write something new
const message = `Hello from Bun FFI! (${new Date().toLocaleTimeString()})`;
if (writeFormat("public.utf8-plain-text", message)) {
  console.log(`\nWrote: "${message}"`);
  console.log(
    `Readback: "${readFormat("public.utf8-plain-text")?.toString()}"`,
  );
  console.log(`New change count: ${Number(clip.clipboard_change_count())}`);
} else {
  console.error("\nFailed to write to clipboard");
}
