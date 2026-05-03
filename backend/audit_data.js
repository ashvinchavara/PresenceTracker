const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    // 1. Find duplicate emails
    db.all("SELECT email, COUNT(*) as count FROM users GROUP BY email HAVING count > 1", [], (err, rows) => {
        if (err) console.error(err);
        console.log("--- Duplicate Emails ---");
        console.log(JSON.stringify(rows || [], null, 2));

        // 2. Find users with multiple assignments
        const multiAssignQuery = `
            SELECT u.email, u.full_name, COUNT(ua.id) as assign_count 
            FROM user_assignments ua 
            JOIN users u ON ua.user_id = u.id 
            GROUP BY u.email 
            HAVING assign_count > 1
        `;
        db.all(multiAssignQuery, [], (err2, rows2) => {
            if (err2) console.error(err2);
            console.log("--- Users with Multi-Assignments ---");
            console.log(JSON.stringify(rows2 || [], null, 2));
            db.close();
        });
    });
});
