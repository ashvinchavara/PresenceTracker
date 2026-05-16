const mysql = require('mysql2');

const cloudConfig = {
    host: 'mysql-38c028d2-ashvinchavara-adtendo.h.aivencloud.com',
    port: 14316,
    user: 'avnadmin',
    password: 'AVNS_yu3jeNWMM5zc7aL7EIl',
    database: 'adtendo',
    ssl: { rejectUnauthorized: false }
};

const userId = 16; // From the previous output (SREYA SATHYAN)

const query = `
    SELECT 
        act.id as activity_id,
        TRIM(act.name) as activity_name,
        DATE_FORMAT(a.date, '%Y-%m-%d') as date_str,
        a.date as raw_date,
        CONCAT(TIME_FORMAT(t.start_time, '%h:%i %p'), ' - ', TIME_FORMAT(t.end_time, '%h:%i %p')) as time_range,
        MAX(CASE WHEN a.user_id = ? THEN 1 ELSE 0 END) as is_present,
        MAX(CASE WHEN a.user_id = ? THEN IFNULL(TIME_FORMAT(a.entry_time, '%H:%i:%s'), 'MISSING') ELSE NULL END) as entry_time,
        MAX(CASE WHEN a.user_id = ? THEN IFNULL(TIME_FORMAT(a.exit_time, '%H:%i:%s'), 'MISSING') ELSE NULL END) as exit_time
    FROM attendance a
    JOIN timetable t ON a.timetable_id = t.id
    JOIN activities act ON t.activity_id = act.id
    JOIN timetable_users tu ON t.id = tu.timetable_id
    WHERE tu.user_id = ?
    GROUP BY act.id, a.date, t.id
    ORDER BY a.date DESC
    LIMIT 5
`;

async function check() {
    let conn;
    try {
        const pool = mysql.createPool(cloudConfig);
        const promisePool = pool.promise();
        
        console.log('Running server query for userId:', userId);
        const [rows] = await promisePool.query(query, [userId, userId, userId, userId]);
        console.table(rows);
        
        await pool.end();
    } catch (err) {
        console.error('Error:', err.message);
    }
}

check();
