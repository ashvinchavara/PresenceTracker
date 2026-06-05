const mysql = require('mysql2/promise');

const cloudConfig = {
    host: 'mysql-38c028d2-ashvinchavara-adtendo.h.aivencloud.com',
    port: 14316,
    user: 'avnadmin',
    password: 'AVNS_yu3jeNWMM5zc7aL7EIl',
    database: 'adtendo',
    ssl: { rejectUnauthorized: false }
};

async function run() {
    const pool = mysql.createPool(cloudConfig);
    const [result] = await pool.query(
        "UPDATE timetable SET end_date = '2027-12-31' WHERE end_date IS NULL OR end_date <= CURDATE()"
    );
    console.log('Updated rows:', result.affectedRows);
    await pool.end();
}

run().catch(e => { console.error(e.message); process.exit(1); });
