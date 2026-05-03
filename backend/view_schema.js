const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.all("SELECT sql FROM sqlite_master WHERE type='table' AND (name='users' OR name='user_assignments')", [], (err, rows) => {
    if (err) console.error(err);
    rows.forEach(r => console.log(r.sql));
    db.close();
});
