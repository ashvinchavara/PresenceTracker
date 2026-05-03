const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    // This regex-like replacement in SQLite is tricky, better to do it in JS
    db.all("SELECT id, email FROM users WHERE email LIKE '[%'", [], (err, rows) => {
        if (err) { console.error(err); return; }
        
        console.log(`Found ${rows.length} potentially malformed emails.`);
        
        const updates = rows.map(row => {
            // Pattern: [email](mailto:email) or [email](anything)
            // We want just the email part. Usually it's better to extract what's inside [ ] or (mailto: )
            let email = row.email;
            
            // Try to extract from [email]
            const bracketMatch = email.match(/\[([^\]]+)\]/);
            if (bracketMatch) {
                email = bracketMatch[1];
            } else {
                // Try to extract from (mailto:email)
                const parenMatch = email.match(/\(mailto:([^\)]+)\)/);
                if (parenMatch) {
                    email = parenMatch[1];
                }
            }
            
            return { id: row.id, cleanEmail: email.trim() };
        });

        if (updates.length === 0) {
            console.log("No malformed emails found with '[' prefix.");
            db.close();
            return;
        }

        db.run("BEGIN TRANSACTION");
        let completed = 0;
        updates.forEach(upd => {
            db.run("UPDATE users SET email = ? WHERE id = ?", [upd.cleanEmail, upd.id], (err) => {
                if (err) console.error(`Failed to update ${upd.id}:`, err);
                completed++;
                if (completed === updates.length) {
                    db.run("COMMIT", () => {
                        console.log(`Successfully cleaned ${completed} emails.`);
                        db.close();
                    });
                }
            });
        });
    });
});
