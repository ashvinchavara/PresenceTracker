const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.all("PRAGMA table_info(user_assignments)", [], (err, rows) => {
    if (err) console.error(err);
    console.log("Schema:", JSON.stringify(rows, null, 2));
    db.close();
});
