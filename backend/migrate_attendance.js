const mysql = require('mysql2/promise');

const cloudConfig = {
    host: 'mysql-38c028d2-ashvinchavara-adtendo.h.aivencloud.com',
    port: 14316,
    user: 'avnadmin',
    password: 'AVNS_yu3jeNWMM5zc7aL7EIl',
    database: 'adtendo',
    ssl: { rejectUnauthorized: false }
};

const localConfig = {
    host: '127.0.0.1',
    user: 'root',
    password: '1021',
    database: 'adtendo'
};

async function migrate(config, label) {
    console.log(`\n--- Migrating ${label} ---`);
    let connection;
    try {
        connection = await mysql.createConnection(config);
        console.log(`Connected to ${label}.`);

        const [columns] = await connection.query('SHOW COLUMNS FROM attendance');
        const hasEntry = columns.some(c => c.Field === 'entry_time');
        const hasExit = columns.some(c => c.Field === 'exit_time');

        if (!hasEntry) {
            await connection.query('ALTER TABLE attendance ADD COLUMN entry_time TIME NULL');
            console.log('✅ Added entry_time column.');
        } else {
            console.log('ℹ️ entry_time already exists.');
        }

        if (!hasExit) {
            await connection.query('ALTER TABLE attendance ADD COLUMN exit_time TIME NULL');
            console.log('✅ Added exit_time column.');
        } else {
            console.log('ℹ️ exit_time already exists.');
        }

    } catch (err) {
        console.error(`❌ Error migrating ${label}:`, err.message);
    } finally {
        if (connection) await connection.end();
    }
}

async function runAll() {
    await migrate(localConfig, 'Local MySQL');
    await migrate(cloudConfig, 'Aiven Cloud MySQL');
    console.log('\nMigration complete.');
    process.exit(0);
}

runAll();
