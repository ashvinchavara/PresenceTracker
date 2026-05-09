const mysql = require('mysql2/promise');

async function seedAttendance() {
    const config = {
        host: 'localhost',
        user: 'root',
        password: '1021',
        database: 'adtendo'
    };

    try {
        const connection = await mysql.createConnection(config);
        console.log('Connected to database.');

        // 1. Get users from department 2
        const [users] = await connection.execute('SELECT id FROM users WHERE dept_id = 2');
        
        if (users.length === 0) {
            console.log('No users found in department 2.');
            await connection.end();
            return;
        }

        console.log(`Found ${users.length} users in department 2.`);

        // 2. Parameters
        const timetableId = 5;
        const markedBy = 10;
        const date = '2026-05-05';

        // 3. Insert attendance for a random subset of these users (e.g., 80% of them)
        let count = 0;
        for (const user of users) {
            if (Math.random() > 0.2) { // 80% chance of being present
                await connection.execute(
                    'INSERT IGNORE INTO attendance (timetable_id, user_id, marked_by, date) VALUES (?, ?, ?, ?)',
                    [timetableId, user.id, markedBy, date]
                );
                count++;
            }
        }

        console.log(`Successfully inserted ${count} attendance records for ${date}.`);
        await connection.end();
    } catch (err) {
        console.error('Error:', err.message);
    }
}

seedAttendance();
