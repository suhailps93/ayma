import asyncio
import os
from google.cloud.sql.connector import Connector
import asyncpg

async def main():
    async with Connector() as connector:
        async def getconn() -> asyncpg.Connection:
            conn: asyncpg.Connection = await connector.connect_async(
                "ayma-ai:us-central1:ayma-db-instance",
                "asyncpg",
                user="ayma-user",
                password="AymaSuperSecret2026!",
                db="ayma",
            )
            return conn

        print("Connecting to Cloud SQL...")
        conn = await getconn()
        
        print("Reading schema.sql...")
        with open("schema.sql", "r") as f:
            schema = f.read()

        print("Applying schema...")
        await conn.execute(schema)
        
        print("Schema applied successfully!")
        await conn.close()

if __name__ == "__main__":
    asyncio.run(main())
