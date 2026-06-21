import asyncio
import asyncpg

async def main():
    print("Connecting to local Cloud SQL proxy...")
    conn = await asyncpg.connect(
        user="ayma-user",
        password="AymaSuperSecret2026!",
        database="ayma",
        host="127.0.0.1",
        port=5433
    )
    
    print("Reading schema.sql...")
    with open("schema.sql", "r") as f:
        schema = f.read()

    print("Applying schema...")
    await conn.execute(schema)
    
    print("Schema applied successfully!")
    await conn.close()

if __name__ == "__main__":
    asyncio.run(main())
