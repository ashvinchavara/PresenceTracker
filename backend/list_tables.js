const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.all("SELECT name FROM sqlite_master WHERE type='table'", [], (err, rows) => {
    if (err) console.error(err);
    console.log("Tables:", JSON.stringify(rows, null, 2));
    db.close();
});
