const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

// Get SQL from command line arguments
const sql = process.argv.slice(2).join(' ');

if (!sql) {
    console.log('Usage: node backend/query.js "SELECT * FROM users"');
    process.exit(0);
}

const isQuery = sql.trim().toUpperCase().startsWith('SELECT') || sql.trim().toUpperCase().startsWith('PRAGMA');

if (isQuery) {
    db.all(sql, [], (err, rows) => {
        if (err) {
            console.error('Error:', err.message);
        } else {
            console.table(rows);
        }
        db.close();
    });
} else {
    db.run(sql, [], function(err) {
        if (err) {
            console.error('Error:', err.message);
        } else {
            console.log(`Success! Changes: ${this.changes}, Last ID: ${this.lastID}`);
        }
        db.close();
    });
}
