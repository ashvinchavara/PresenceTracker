const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.get('SELECT email, full_name FROM users WHERE full_name LIKE ?', ['%ABHAYJITH%'], (err, row) => {
    if (err) console.error(err);
    console.log("Check result:", JSON.stringify(row, null, 2));
    db.close();
});
