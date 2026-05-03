const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    console.log("--- Users Schema ---");
    db.all("PRAGMA table_info(users)", [], (err, rows) => {
        console.log("Columns:", JSON.stringify(rows, null, 2));
    });
    db.all("PRAGMA index_list(users)", [], (err, rows) => {
        console.log("Indexes:", JSON.stringify(rows, null, 2));
    });

    console.log("--- User Assignments Schema ---");
    db.all("PRAGMA table_info(user_assignments)", [], (err, rows) => {
        console.log("Columns:", JSON.stringify(rows, null, 2));
    });
    db.all("PRAGMA index_list(user_assignments)", [], (err, rows) => {
        console.log("Indexes:", JSON.stringify(rows, null, 2));
    });

    // Cross-check for duplicate emails again, just to be 100% sure
    db.all("SELECT email, COUNT(*) as c FROM users GROUP BY email HAVING c > 1", [], (err, rows) => {
        console.log("Duplicate Emails:", JSON.stringify(rows, null, 2));
    });

    // Duplicate assignments for same user ID
    db.all("SELECT user_id, COUNT(*) as c FROM user_assignments GROUP BY user_id HAVING c > 1", [], (err, rows) => {
        console.log("Duplicate Assignments (by ID):", JSON.stringify(rows, null, 2));
        db.close();
    });
});
