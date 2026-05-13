-- Normalization Migration Script

USE adtendo;

-- 1. Activities Table
CREATE TABLE IF NOT EXISTS activities (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE
);

-- Populate Activities
INSERT IGNORE INTO activities (name)
SELECT DISTINCT activity_name FROM timetable WHERE activity_name IS NOT NULL;

-- Add activity_id to timetable
ALTER TABLE timetable ADD COLUMN activity_id INT;

-- Map names to IDs
UPDATE timetable t
JOIN activities a ON t.activity_name = a.name
SET t.activity_id = a.id;

-- Drop activity_name and set FK
ALTER TABLE timetable DROP COLUMN activity_name;
ALTER TABLE timetable ADD CONSTRAINT fk_timetable_activity FOREIGN KEY (activity_id) REFERENCES activities(id);

-- 2. Roles Table
CREATE TABLE IF NOT EXISTS roles (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE
);

-- Populate Roles
INSERT IGNORE INTO roles (name)
SELECT DISTINCT role FROM users WHERE role IS NOT NULL;

-- Add role_id to users
ALTER TABLE users ADD COLUMN role_id INT;

-- Map roles to IDs
UPDATE users u
JOIN roles r ON u.role = r.name
SET u.role_id = r.id;

-- Drop role and set FK
ALTER TABLE users DROP COLUMN role;
ALTER TABLE users ADD CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles(id);
