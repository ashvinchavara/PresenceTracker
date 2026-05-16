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

async function sync() {
    let localConn, cloudConn;
    try {
        console.log('Connecting to databases...');
        localConn = await mysql.createConnection(localConfig);
        cloudConn = await mysql.createConnection(cloudConfig);

        console.log('✅ Connected to both local and cloud databases.');

        // Ensure temporary_upload_power exists on cloud
        await cloudConn.query(`
            CREATE TABLE IF NOT EXISTS temporary_upload_power (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT,
                timetable_id INT,
                date DATE,
                granted_by INT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        `);
        console.log('Verified temporary_upload_power table on cloud.');

        const tables = [
            'roles',
            'departments',
            'users',
            'activities',
            'timetable',
            'timetable_days',
            'timetable_users',
            'attendance',
            'temporary_upload_power'
        ];

        // Disable foreign key checks for the sync process
        await cloudConn.query('SET FOREIGN_KEY_CHECKS = 0');
        console.log('Disabled foreign key checks on cloud DB.');

        for (const table of tables) {
            console.log(`Syncing table: ${table}...`);
            
            // Get local data
            const [rows] = await localConn.query(`SELECT * FROM ${table}`);
            console.log(`  Read ${rows.length} rows from local ${table}.`);

            // Clear cloud table
            await cloudConn.query(`TRUNCATE TABLE ${table}`);
            
            if (rows.length > 0) {
                const columns = Object.keys(rows[0]);
                const placeholders = columns.map(() => '?').join(', ');
                const insertSql = `INSERT INTO ${table} (${columns.join(', ')}) VALUES (${placeholders})`;
                
                // Bulk insert in chunks of 100 to be safe and efficient
                const chunkSize = 100;
                for (let i = 0; i < rows.length; i += chunkSize) {
                    const chunk = rows.slice(i, i + chunkSize);
                    const bulkInsertSql = `INSERT INTO ${table} (${columns.join(', ')}) VALUES ?`;
                    const bulkValues = chunk.map(row => columns.map(col => row[col]));
                    await cloudConn.query(bulkInsertSql, [bulkValues]);
                    console.log(`  Inserted rows ${i + 1} to ${Math.min(i + chunkSize, rows.length)} of ${rows.length} into cloud ${table}.`);
                }
            }
        }

        await cloudConn.query('SET FOREIGN_KEY_CHECKS = 1');
        console.log('Re-enabled foreign key checks on cloud DB.');
        console.log('🚀 Sync complete!');

    } catch (err) {
        console.error('❌ Sync failed:', err.message);
        if (cloudConn) {
            await cloudConn.query('SET FOREIGN_KEY_CHECKS = 1');
        }
    } finally {
        if (localConn) await localConn.end();
        if (cloudConn) await cloudConn.end();
        process.exit(0);
    }
}

sync();
