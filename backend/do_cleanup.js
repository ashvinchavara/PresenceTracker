const sqlite3 = require('sqlite3').verbose();
const db = new sqlite3.Database('backend/adtendo.db');

db.serialize(() => {
    db.run("BEGIN TRANSACTION");

    // 1. Get all users
    db.all("SELECT id, email FROM users ORDER BY id ASC", [], (err, allUsers) => {
        if (err) { console.error(err); return; }

        const emailToGoodId = {}; // email -> lowest id
        const badIds = [];
        const idMap = {}; // badId -> goodId

        allUsers.forEach(u => {
            const email = (u.email || '').toLowerCase().trim();
            if (!email) return; 
            if (emailToGoodId[email] === undefined) {
                emailToGoodId[email] = u.id;
            } else {
                badIds.push(u.id);
                idMap[u.id] = emailToGoodId[email];
            }
        });

        console.log(`Found ${badIds.length} duplicate users to merge.`);

        // 2. Update assignments to point to good IDs
        let p = Promise.resolve();
        for (const badId in idMap) {
            const goodId = idMap[badId];
            p = p.then(() => new Promise((resolve) => {
                db.run("UPDATE user_assignments SET user_id = ? WHERE user_id = ?", [goodId, badId], (err) => {
                    if (err) console.error(err);
                    resolve();
                });
            }));
        }

        p.then(() => {
            // 3. Remove duplicate assignments for same user_id in user_assignments
            // We keep the one with lowest ID
            db.run(`
                DELETE FROM user_assignments 
                WHERE id NOT IN (
                    SELECT MIN(id) FROM user_assignments GROUP BY user_id
                )
            `, (err) => {
                if (err) console.error(err);

                // 4. Delete bad users
                db.run(`DELETE FROM users WHERE id IN (${badIds.length > 0 ? badIds.join(',') : '0'})`, (err) => {
                    if (err) console.error(err);

                    console.log("Cleanup phase 1 complete. Proceeding to schema enforcement.");
                    db.run("COMMIT", () => {
                        db.close();
                    });
                });
            });
        });
    });
});
