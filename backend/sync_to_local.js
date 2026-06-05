const mysql = require('mysql2/promise');

const cloudConfig = {
    host: 'mysql-38c028d2-ashvinchavara-adtendo.h.aivencloud.com',
    port: 14316,
    user: 'avnadmin',
    password: 'AVNS_yu3jeNWMM5zc7aL7EIl',
    database: 'adtendo',
    ssl: { rejectUnauthorized: false },
    multipleStatements: true
};

const localConfig = {
    host: '127.0.0.1',
    user: 'root',
    password: '1021',
    database: 'adtendo',
    multipleStatements: true
};

// Tables in dependency order (parents before children)
const TABLES = [
    'departments',
    'users',
    'activities',
    'timetable',
    'timetable_days',
    'timetable_users',
    'attendance',
    'settings',
];

async function syncTable(cloudPool, localPool, table) {
    // Fetch all rows from cloud
    const [rows] = await cloudPool.query(`SELECT * FROM \`${table}\``);
    console.log(`  [${table}] ${rows.length} rows from cloud`);

    if (rows.length === 0) {
        // Just truncate local
        await localPool.query(`DELETE FROM \`${table}\``);
        console.log(`  [${table}] cleared (empty on cloud)`);
        return;
    }

    // Build column list from first row
    const cols = Object.keys(rows[0]).map(c => `\`${c}\``).join(', ');
    const placeholders = Object.keys(rows[0]).map(() => '?').join(', ');

    // Clear local table
    await localPool.query(`DELETE FROM \`${table}\``);

    // Batch insert in chunks of 100
    const chunkSize = 100;
    for (let i = 0; i < rows.length; i += chunkSize) {
        const chunk = rows.slice(i, i + chunkSize);
        for (const row of chunk) {
            await localPool.query(
                `INSERT INTO \`${table}\` (${cols}) VALUES (${placeholders})`,
                Object.values(row)
            );
        }
    }
    console.log(`  [${table}] ✅ synced`);
}

async function run() {
    console.log('🔌 Connecting to both databases...');
    const cloudPool = await mysql.createPool(cloudConfig);
    const localPool  = await mysql.createPool(localConfig);

    // Test connections
    await cloudPool.query('SELECT 1');
    console.log('✅ Cloud DB connected');
    await localPool.query('SELECT 1');
    console.log('✅ Local DB connected');

    // Disable FK checks on local to allow clean truncation
    await localPool.query('SET FOREIGN_KEY_CHECKS = 0');

    for (const table of TABLES) {
        try {
            await syncTable(cloudPool, localPool, table);
        } catch (e) {
            console.error(`  ❌ [${table}] Error: ${e.message}`);
        }
    }

    // Re-enable FK checks
    await localPool.query('SET FOREIGN_KEY_CHECKS = 1');

    await cloudPool.end();
    await localPool.end();

    console.log('\n🎉 Sync complete! Local DB now mirrors the Cloud DB.');
}

run().catch(e => {
    console.error('Fatal:', e.message);
    process.exit(1);
});
