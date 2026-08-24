import { appendFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "pg";

const connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  throw new Error("DATABASE_URL is required");
}

const client = new Client({ connectionString });

try {
  await client.connect();
  const { rows } = await client.query("select current_database() as database");
  const projectRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
  const markerPath = join(projectRoot, ".treeman-lab", "post-create.log");
  await mkdir(dirname(markerPath), { recursive: true });
  await appendFile(markerPath, `${rows[0].database}\n`);
  console.log(`Post-create hook verified ${rows[0].database}`);
} finally {
  await client.end();
}
