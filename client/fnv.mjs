// Prints the FNV-1a 64-bit hash of a file in 16 hex digits, as gweb's ETags.
import fs from "node:fs";
let h = 0xcbf29ce484222325n;
for (const b of fs.readFileSync(process.argv[2])) h = ((h ^ BigInt(b)) * 0x100000001b3n) & 0xffffffffffffffffn;
console.log(h.toString(16).padStart(16, "0"));
