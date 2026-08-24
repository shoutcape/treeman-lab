import { Client } from "pg";

const connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  throw new Error("DATABASE_URL is required");
}

const client = new Client({ connectionString });

try {
  await client.connect();
  const { rows } = await client.query(
    "select current_database() as database, current_user as user",
  );
  console.log(`Connected to ${rows[0].database} as ${rows[0].user}`);
} finally {
  await client.end();
}
