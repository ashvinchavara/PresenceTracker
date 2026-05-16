// app.js - Direct MySQL Connection Logic
let API_BASE = 'https://presencetracker.onrender.com/api';

// Shared State
let state = {
    departments: [], // Recursive Tree
    users: [],
    timetable: [],
    attendance: [],
    activities: [],
    roles: [],
    sort: {
        column: 'full_name',
        direction: 'asc'
    },
    selectedNodeFilter: null
};

let selectedPickerUsers = []; // For Timetable Assignment

function convertTo24h(timeStr, ampm) {
    if (!timeStr || !timeStr.includes(':')) return '00:00:00';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    if (ampm === 'PM' && hours < 12) hours += 12;
    if (ampm === 'AM' && hours === 12) hours = 0;
    return `${hours.toString().padStart(2, '0')}:${minutes.padStart(2, '0')}:00`;
}

function parse24h(time24) {
    if (!time24) return { time: '12:00', ampm: 'AM' };
    let [hours, minutes] = time24.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12;
    return {
        time: `${hours.toString().padStart(2, '0')}:${minutes}`,
        ampm: ampm
    };
}

function convertTo24h(timeStr, ampm) {
    if (!timeStr || !timeStr.includes(':')) return '00:00:00';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    if (ampm === 'PM' && hours < 12) hours += 12;
    if (ampm === 'AM' && hours === 12) hours = 0;
    return `${hours.toString().padStart(2, '0')}:${minutes.padStart(2, '0')}:00`;
}

function parse24h(time24) {
    if (!time24) return { time: '12:00', ampm: 'AM' };
    let [hours, minutes] = time24.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12;
    return {
        time: `${hours.toString().padStart(2, '0')}:${minutes}`,
        ampm: ampm
    };
}

// --- Initialization ---

document.addEventListener('DOMContentLoaded', () => {
    initApp();
});

async function initApp() {
    initTheme();
    setupEventListeners();
    await loadAllData();
}

function initTheme() {
    const savedTheme = localStorage.getItem('theme') || 'dark';
    document.documentElement.setAttribute('data-theme', savedTheme);
    updateThemeUI(savedTheme);
}

function toggleTheme() {
    const currentTheme = document.documentElement.getAttribute('data-theme');
    const newTheme = currentTheme === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', newTheme);
    localStorage.setItem('theme', newTheme);
    updateThemeUI(newTheme);
}

function updateThemeUI(theme) {
    const toggleBtn = document.getElementById('theme-toggle');
    const themeText = document.getElementById('theme-text');
    if (!toggleBtn || !themeText) return;

    if (theme === 'light') {
        toggleBtn.innerHTML = '<span class="material-symbols-rounded">light_mode</span>';
        themeText.innerText = 'Light Mode';
        toggleBtn.style.transform = 'rotate(180deg)';
    } else {
        toggleBtn.innerHTML = '<span class="material-symbols-rounded">dark_mode</span>';
        themeText.innerText = 'Dark Mode';
        toggleBtn.style.transform = 'rotate(0deg)';
    }
}

async function loadAllData() {
    const statusIndicator = document.getElementById('db-status');
    const connectionText = document.getElementById('connection-text');

    const [depts, users, tt, att, acts, roles, dbStatus] = await Promise.all([
        apiFetch('/departments'),
        apiFetch('/users'),
        apiFetch('/timetable'),
        apiFetch('/attendance'),
        apiFetch('/activities'),
        apiFetch('/roles'),
        apiFetch('/db-status')
    ]);

    if (depts) {
        state.departments = depts;
        state.users = users;
        state.timetable = tt;
        state.attendance = att;
        state.activities = acts || [];
        state.roles = roles || [];

        statusIndicator.classList.add('connected');
        
        if (dbStatus && dbStatus.mode === 'cloud') {
            connectionText.innerHTML = `Connected to <span style="color: var(--success);">Aiven Cloud</span>`;
            statusIndicator.style.background = 'var(--success)';
        } else {
            connectionText.innerHTML = `Connected to <span style="color: var(--warning);">Local MySQL</span> (Offline Fallback)`;
            statusIndicator.style.background = 'var(--warning)';
        }
        
        renderUI();
    } else {
        connectionText.innerText = 'Offline / Error';
        statusIndicator.classList.remove('connected');
        statusIndicator.style.background = 'var(--danger)';
    }
}

function renderUI() {
    renderOverview();
    renderUserAssignments();
    renderTimetable();
    renderAttendanceLogs();
    renderUploadPermissions();
    populateNodeDropdown();
    populateActivityDropdown();
    populateSelectors();
    populateDatalists();
}

function populateDatalists() {
    const rolesDl = document.getElementById('existing-roles');
    if (rolesDl) {
        rolesDl.innerHTML = state.roles.map(r => `<option value="${r.name}">`).join('');
    }
    const actsDl = document.getElementById('existing-activities');
    if (actsDl) {
        actsDl.innerHTML = state.activities.map(a => `<option value="${a.name}">`).join('');
    }
}

// --- API Helpers ---

async function apiFetch(endpoint) {
    try {
        const response = await fetch(`${API_BASE}${endpoint}`);
        return await response.json();
    } catch (e) {
        console.error(`Fetch failed: ${e.message}`);
        return null;
    }
}

async function apiPost(endpoint, data) {
    try {
        const response = await fetch(`${API_BASE}${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        return await response.json();
    } catch (e) {
        console.error(`Post failed: ${e.message}`);
    }
}

// --- 1. Overview (Departments) ---

function renderOverview() {
    const tableBody = document.getElementById('deps-table-body');
    if (!tableBody) return;
    tableBody.innerHTML = '';

    // Filter root departments (parent_id is null)
    const roots = state.departments.filter(d => !d.parent_id);

    roots.forEach(dept => {
        const isActive = dept.status !== 0 && dept.status !== false && dept.status !== null;
        tableBody.innerHTML += `
            <tr class="${isActive ? '' : 'inactive-dept'}">
                <td onclick="openNodeExplorer(${dept.id})" style="cursor: pointer;">
                    <strong style="color: var(--primary);">${dept.name}</strong>
                    <br>
                </td>
                <td>
                    <span class="badge ${isActive ? 'success' : 'danger'}" 
                          onclick="event.stopPropagation(); toggleDeptStatus(${dept.id}, ${isActive})" 
                          style="cursor: pointer;">
                        ${isActive ? 'Active' : 'Inactive'}
                    </span>
                </td>
            </tr>
        `;
    });
}

window.toggleDeptStatus = async (id, currentStatus) => {
    const newStatus = currentStatus ? 0 : 1;

    // 1. Update the target department
    await fetch(`${API_BASE}/departments/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: newStatus })
    });

    // 2. If deactivating, strictly deactivate all descendants
    if (newStatus === 0) {
        const descendants = getAllDescendantIds(id);
        for (const childId of descendants) {
            await fetch(`${API_BASE}/departments/${childId}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ status: 0 })
            });
        }
    }

    await loadAllData();

    // If modal is open for this ID, refresh it
    const modal = document.getElementById('details-modal');
    if (modal && modal.style.display === 'flex') {
        openNodeExplorer(id);
    }
};

function getAllDescendantIds(parentId) {
    let ids = [];
    const children = state.departments.filter(d => d.parent_id === parentId);
    children.forEach(child => {
        ids.push(child.id);
        ids = ids.concat(getAllDescendantIds(child.id));
    });
    return ids;
}

function isAncestorInactive(deptId) {
    if (!deptId) return false;
    let current = state.departments.find(d => d.id === deptId);
    while (current && current.parent_id) {
        let parent = state.departments.find(d => d.id === current.parent_id);
        if (parent && !parent.status) return true;
        current = parent;
    }
    return false;
}

function getAncestors(id) {
    const path = [];
    if (!id) return path;

    // Add root entry
    path.push({ name: 'Global Root', id: null });

    let current = state.departments.find(d => d.id === id);
    let ancestors = [];
    while (current && current.parent_id) {
        let parent = state.departments.find(d => d.id === current.parent_id);
        if (parent) ancestors.unshift(parent);
        current = parent;
    }
    return path.concat(ancestors);
}

function getFullDeptPath(deptId) {
    if (!deptId) return 'Unassigned';
    const ancestors = getAncestors(deptId);
    const current = state.departments.find(d => d.id === deptId);
    const pathParts = ancestors
        .filter(a => a.id !== null) // Skip 'Global Root'
        .map(a => a.name);
    if (current) pathParts.push(current.name);
    return pathParts.join(' <span style="opacity: 0.3; margin: 0 4px;">&rsaquo;</span> ');
}

window.openNodeExplorer = (id) => {
    let dept = state.departments.find(d => d.id === id);

    // If no ID, show root explorer
    if (!dept) {
        dept = { name: 'Infrastructure Root', id: null, status: 1, parent_id: null };
    }

    const deptUsers = state.users.filter(u => u.dept_id === id);
    const deptSchedules = state.timetable.filter(t => t.dept_id === id);
    const subDepts = state.departments.filter(d => d.parent_id === id);

    // Update Modal Rail
    const ancestors = getAncestors(id);
    const rail = document.getElementById('modal-ancestors');
    const stack = document.getElementById('ancestor-stack');

    if (ancestors.length > 0) {
        rail.style.display = 'block';
        stack.innerHTML = `
            <ul class="nav-links">
                ${ancestors.map(anc => `
                    <li onclick="openNodeExplorer(${anc.id})" style="gap: 10px; padding: 10px 14px;">
                        <span class="material-symbols-rounded" style="font-size: 18px; opacity: 0.6;">subdirectory_arrow_right</span>
                        <span style="font-size: 13px;">${anc.name}</span>
                    </li>
                `).join('')}
            </ul>
        `;
    } else {
        rail.style.display = 'none';
    }

    document.getElementById('modal-title').innerText = dept.name;
    document.getElementById('modal-subtitle').innerText = id ? 'Department Infrastructure Node' : 'Global Infrastructure Overview';

    const modalList = document.getElementById('modal-list');
    modalList.innerHTML = `
        <div style="padding: 40px; display: flex; flex-direction: column; align-items: center; gap: 30px;">
            <!-- Picker-style Header with Actions -->
            <div class="custom-input dropdown-trigger" style="width: 800px; padding: 20px 30px; cursor: default; display: flex; justify-content: space-between; align-items: center; background: rgba(99, 102, 241, 0.1); border: 1px solid var(--primary); border-radius: 20px;">
                <div style="display: flex; flex-direction: column;">
                    <span class="text-muted" style="font-size: 11px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 4px;">Active Context</span>
                    <span style="font-size: 18px; font-weight: 700; color: var(--text-main);">${dept.name}</span>
                </div>
                
                <div style="display: flex; align-items: center; gap: 15px;">
                    <div style="display: flex; gap: 8px; background: rgba(0,0,0,0.2); padding: 6px; border-radius: 12px; border: 1px solid var(--glass-border);">
                        <button class="btn-icon-small" onclick="addNewSubDept(${id})" title="Add Sub-Node">
                            <span class="material-symbols-rounded" style="color: var(--success); font-size: 18px;">add_box</span>
                        </button>
                        ${id ? `
                            <button class="btn-icon-small" onclick="editDeptName(${id}, '${dept.name}')" title="Edit Node">
                                <span class="material-symbols-rounded" style="color: var(--warning); font-size: 18px;">edit</span>
                            </button>
                            <button class="btn-icon-small" 
                                ${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? `onclick="deleteDept(${id})"` : 'disabled'} 
                                title="${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? 'Delete Node' : 'Cannot delete: Node contains personnel, sub-nodes, or active schedules'}"
                                style="${deptUsers.length === 0 && deptSchedules.length === 0 && subDepts.length === 0 ? '' : 'opacity: 0.3; cursor: not-allowed; filter: grayscale(1);'}">
                                <span class="material-symbols-rounded" style="color: var(--danger); font-size: 18px;">delete</span>
                            </button>
                        ` : ''}
                    </div>
                    <span class="badge ${dept.status ? 'success' : 'danger'}" 
                          ${isAncestorInactive(id) ? '' : `onclick="toggleDeptStatus(${id}, ${dept.status})"`} 
                          style="cursor: ${isAncestorInactive(id) ? 'not-allowed' : 'pointer'}; opacity: ${isAncestorInactive(id) && !dept.status ? '0.5' : '1'};"
                          title="${isAncestorInactive(id) ? 'Status locked: Parent node is inactive' : 'Click to toggle status (Cascades to sub-nodes if deactivating)'}">
                        ${dept.status ? 'Active' : 'Inactive'}
                    </span>
                </div>
            </div>

            <div class="glass-panel" style="width: 800px; padding: 40px;">
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 40px;">
                    <div>
                        <h3 style="margin-bottom: 20px; font-size: 14px; color: var(--text-muted); text-transform: uppercase; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">Node Intelligence</h3>
                        
                        <div style="display: flex; flex-direction: column; gap: 15px;">
                            <div class="clickable-stat" onclick="showDeptUsers(${id})" style="cursor: pointer; padding: 15px; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid var(--glass-border); transition: all 0.2s;">
                                <div style="display: flex; justify-content: space-between; align-items: center;">
                                    <div>
                                        <span style="display: block; font-size: 24px; font-weight: 700; color: var(--primary);">${deptUsers.length}</span>
                                        <span style="font-size: 12px; color: var(--text-muted); text-transform: uppercase;">Personnel Assigned</span>
                                    </div>
                                    <span class="material-symbols-rounded" style="color: var(--primary); opacity: 0.5;">group</span>
                                </div>
                            </div>

                            <div class="clickable-stat" onclick="showDeptSchedules(${id})" style="cursor: pointer; padding: 15px; background: rgba(255,255,255,0.03); border-radius: 12px; border: 1px solid var(--glass-border); transition: all 0.2s;">
                                <div style="display: flex; justify-content: space-between; align-items: center;">
                                    <div>
                                        <span style="display: block; font-size: 24px; font-weight: 700; color: var(--accent-blue);">${deptSchedules.length}</span>
                                        <span style="font-size: 12px; color: var(--text-muted); text-transform: uppercase;">Active Schedules</span>
                                    </div>
                                    <span class="material-symbols-rounded" style="color: var(--accent-blue); opacity: 0.5;">calendar_today</span>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <div id="modal-content-area">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
                            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">
                                ${id ? 'Sub-Nodes' : 'Infrastructure Branches'}
                            </h3>
                        </div>
                        <div id="modal-child-tree" class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 20px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
                            ${buildTreeHTML(id, 'explorer') || '<p class="text-muted" style="text-align: center; padding: 20px;">No further sub-nodes in this branch.</p>'}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    `;

    document.getElementById('details-modal').style.display = 'flex';
};

window.showDeptUsers = (id) => {
    const users = state.users.filter(u => u.dept_id === id);
    const area = document.getElementById('modal-content-area');

    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">Personnel List</h3>
        </div>
        <div class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${users.length ? users.map(u => `
                <div style="display: flex; justify-content: space-between; align-items: center; padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                    <div>
                        <div style="font-weight: 600; font-size: 14px;">${u.full_name}</div>
                        <div style="font-size: 11px; color: var(--text-muted);">${u.role}</div>
                    </div>
                    ${u.can_upload ? '<span class="badge success" style="font-size: 9px; padding: 2px 8px;">Upload Power</span>' : ''}
                </div>
            `).join('') : '<p class="text-muted" style="text-align: center; padding: 20px;">No personnel assigned.</p>'}
        </div>
    `;
};

window.showDeptSchedules = (id) => {
    const schedules = state.timetable.filter(t => t.dept_id === id);
    const area = document.getElementById('modal-content-area');

    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">Operational Schedules</h3>
        </div>
        <div class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${schedules.length ? schedules.map(s => `
                <div style="padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                    <div style="font-weight: 600; font-size: 14px; color: var(--accent-blue);">${s.activity_name}</div>
                    <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">
                        ${s.days} | ${s.start_time.slice(0, 5)} - ${s.end_time.slice(0, 5)}
                    </div>
                </div>
            `).join('') : '<p class="text-muted" style="text-align: center; padding: 20px;">No schedules active.</p>'}
        </div>
    `;
};

window.resetModalView = (id) => {
    const area = document.getElementById('modal-content-area');
    area.innerHTML = `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; border-bottom: 1px solid var(--glass-border); padding-bottom: 10px;">
            <h3 style="font-size: 14px; color: var(--text-muted); text-transform: uppercase; margin: 0;">
                ${id ? 'Sub-Nodes' : 'Infrastructure Branches'}
            </h3>
        </div>
        <div id="modal-child-tree" class="custom-scrollbar" style="max-height: 400px; overflow: auto; padding: 20px; background: rgba(0,0,0,0.2); border-radius: 12px; border: 1px solid var(--glass-border);">
            ${buildTreeHTML(id, 'explorer') || '<p class="text-muted" style="text-align: center; padding: 20px;">No further sub-nodes in this branch.</p>'}
        </div>
    `;
};

window.addNewSubDept = async (parentId) => {
    const name = prompt('Enter name for the new sub-department:');
    if (!name) return;
    await apiPost('/departments', { name, parent_id: parentId });
    await loadAllData();
    openNodeExplorer(parentId);
};

window.editDeptName = async (id, oldName) => {
    const name = prompt('Enter new name for department:', oldName);
    if (!name || name === oldName) return;
    await fetch(`${API_BASE}/departments/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
    });
    await loadAllData();
    openNodeExplorer(id);
};

document.getElementById('btn-close-modal').onclick = () => {
    document.getElementById('details-modal').style.display = 'none';
};

window.deleteDept = async (id) => {
    if (!confirm('Delete this department and all nested levels?')) return;
    await fetch(`${API_BASE}/departments/${id}`, { method: 'DELETE' });
    loadAllData();
};

// --- 2. Users & Assignments ---

function renderUserAssignments() {
    const foldersContainer = document.getElementById('personnel-folders-container');
    const gridBody = document.getElementById('assignments-grid-body');
    const filter = document.getElementById('assignment-name-filter')?.value.toLowerCase() || '';
    
    if (!foldersContainer || !gridBody) return;

    // 1. Render Folders (only show if no search is active, or show all if search is active but allow filtering)
    const nodesWithUsers = new Set(state.users.map(u => u.dept_id));
    const activeNodes = state.departments.filter(d => nodesWithUsers.has(d.id));

    foldersContainer.innerHTML = activeNodes.map(node => `
        <div class="glass-panel folder-card ${state.selectedNodeFilter == node.id ? 'active' : ''}" 
             onclick="filterByNode(${node.id})"
             style="padding: 20px; cursor: pointer; display: flex; align-items: center; gap: 15px; transition: all 0.2s;">
            <div style="width: 40px; height: 40px; border-radius: 10px; background: rgba(99, 102, 241, 0.1); display: flex; align-items: center; justify-content: center; color: var(--primary);">
                <span class="material-symbols-rounded">folder</span>
            </div>
            <div style="overflow: hidden;">
                <div style="font-weight: 600; font-size: 14px; white-space: nowrap; text-overflow: ellipsis; overflow: hidden;">${node.name}</div>
                <div style="font-size: 11px; color: var(--text-muted);">${state.users.filter(u => u.dept_id == node.id).length} Members</div>
            </div>
        </div>
    `).join('');

    // 2. Filter Users
    let filteredUsers = [...state.users];
    
    if (state.selectedNodeFilter) {
        filteredUsers = filteredUsers.filter(u => u.dept_id == state.selectedNodeFilter);
        document.getElementById('btn-reset-view').style.display = 'flex';
        document.getElementById('btn-delete-all-node').style.display = 'flex';
        const node = state.departments.find(d => d.id == state.selectedNodeFilter);
        document.getElementById('current-node-selection-title').innerText = node ? `Personnel in ${node.name}` : 'Personnel';
    } else {
        document.getElementById('btn-reset-view').style.display = 'none';
        document.getElementById('btn-delete-all-node').style.display = 'none';
        document.getElementById('current-node-selection-title').innerText = 'All Personnel';
    }

    if (filter) {
        filteredUsers = filteredUsers.filter(u =>
            u.full_name.toLowerCase().includes(filter) ||
            (u.email && u.email.toLowerCase().includes(filter))
        );
    }

    // 3. Render User Cards
    if (filteredUsers.length === 0) {
        gridBody.innerHTML = '<div class="loading-text" style="grid-column: 1 / -1;">No matching personnel found.</div>';
        return;
    }

    gridBody.innerHTML = filteredUsers.map(u => {
        const initialsHtml = `<div class="student-initial">${u.full_name.charAt(0)}</div>`;
        const avatarHtml = u.image_url 
            ? `<img src="${API_BASE.replace('/api', '')}${u.image_url}" 
                 class="student-initial" style="object-fit: cover;"
                 onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';">
               <div class="student-initial" style="display: none;">${u.full_name.charAt(0)}</div>`
            : initialsHtml;

        return `
            <div class="student-card" style="position: relative;">
                <div style="position: absolute; top: 10px; right: 10px; display: flex; gap: 5px;">
                    <button class="btn-icon" style="width: 28px; height: 28px;" onclick="editUserRow(${u.id})">
                        <span class="material-symbols-rounded" style="font-size: 16px;">edit</span>
                    </button>
                    <button class="btn-icon text-danger" style="width: 28px; height: 28px;" onclick="deleteUser(${u.id})">
                        <span class="material-symbols-rounded" style="font-size: 16px;">delete</span>
                    </button>
                </div>
                <div style="position: relative; width: 44px; height: 44px; display: flex; align-items: center; justify-content: center; margin-bottom: 12px;">
                    ${avatarHtml}
                </div>
                <div class="student-info">
                    <span class="student-name">${u.full_name}</span>
                    <span class="student-role">${u.role || 'Personnel'}</span>
                    <span class="text-muted" style="font-size: 10px;">${u.email}</span>
                </div>
            </div>
        `;
    }).join('');
}

window.filterByNode = (nodeId) => {
    state.selectedNodeFilter = (state.selectedNodeFilter === nodeId) ? null : nodeId;
    renderUserAssignments();
};

window.resetPersonnelView = () => {
    state.selectedNodeFilter = null;
    renderUserAssignments();
};

window.deleteAllInNode = async () => {
    if (!state.selectedNodeFilter) return;
    const node = state.departments.find(d => d.id == state.selectedNodeFilter);
    const usersToDelete = state.users.filter(u => u.dept_id == state.selectedNodeFilter);
    
    if (usersToDelete.length === 0) return alert('No personnel in this node.');
    
    if (!confirm(`CRITICAL ACTION: Are you sure you want to delete ALL ${usersToDelete.length} personnel in "${node?.name}"? This cannot be undone.`)) return;

    for (const u of usersToDelete) {
        await fetch(`${API_BASE}/users/${u.id}`, { method: 'DELETE' });
    }

    alert(`Successfully removed all personnel from ${node?.name}.`);
    loadAllData();
};

window.sortAssignments = (column) => {
    if (state.sort.column === column) {
        state.sort.direction = state.sort.direction === 'asc' ? 'desc' : 'asc';
    } else {
        state.sort.column = column;
        state.sort.direction = 'asc';
    }
    renderUserAssignments();
};

window.editUserRow = (id) => {
    const u = state.users.find(user => user.id === id);
    if (!u) return;

    document.getElementById('edit-user-id').value = u.id;
    document.getElementById('edit-user-name').value = u.full_name;
    document.getElementById('edit-user-email').value = u.email;
    document.getElementById('edit-user-role').value = u.role || '';
    
    const deptSelect = document.getElementById('edit-user-dept');
    deptSelect.innerHTML = '<option value="">Unassigned</option>' + 
        state.departments.map(d => `<option value="${d.id}" ${d.id == u.dept_id ? 'selected' : ''}>${d.name}</option>`).join('');

    document.getElementById('edit-user-modal').style.display = 'flex';
};

window.saveUserEditModal = async () => {
    const id = document.getElementById('edit-user-id').value;
    const full_name = document.getElementById('edit-user-name').value;
    const email = document.getElementById('edit-user-email').value;
    const dept_id = document.getElementById('edit-user-dept').value || null;
    const role = document.getElementById('edit-user-role').value;

    const u = state.users.find(user => user.id == id);

    await fetch(`${API_BASE}/users/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            ...u,
            full_name,
            email,
            dept_id,
            role
        })
    });

    document.getElementById('edit-user-modal').style.display = 'none';
    loadAllData();
};

function updateSortIcons() {
    const columns = ['sub_dept_name', 'role_name'];
    columns.forEach(col => {
        const iconId = col === 'sub_dept_name' ? 'sort-icon-node' : 'sort-icon-role';
        const icon = document.getElementById(iconId);
        if (!icon) return;

        if (state.sort.column === col) {
            icon.innerText = state.sort.direction === 'asc' ? 'expand_less' : 'expand_more';
            icon.style.opacity = '1';
            icon.style.color = 'var(--primary)';
        } else {
            icon.innerText = 'unfold_more';
            icon.style.opacity = '0.3';
            icon.style.color = 'inherit';
        }
    });
}

window.toggleAllAssignments = (checked) => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox');
    checkboxes.forEach(cb => cb.checked = checked);
    updateBulkDeleteUI();
};

window.updateBulkDeleteUI = () => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox');
    const selectedCount = Array.from(checkboxes).filter(cb => cb.checked).length;
    const btn = document.getElementById('btn-bulk-delete-assignments');
    const countDisplay = document.getElementById('bulk-delete-count');
    const selectAllCb = document.getElementById('assignment-select-all');

    if (btn && countDisplay) {
        btn.style.display = selectedCount > 0 ? 'flex' : 'none';
        countDisplay.innerText = selectedCount;
    }

    if (selectAllCb) {
        selectAllCb.checked = selectedCount > 0 && selectedCount === checkboxes.length;
        selectAllCb.indeterminate = selectedCount > 0 && selectedCount < checkboxes.length;
    }
};

window.deleteSelectedAssignments = async () => {
    const checkboxes = document.querySelectorAll('.user-select-checkbox:checked');
    const ids = Array.from(checkboxes).map(cb => cb.dataset.id);

    if (ids.length === 0) return;
    if (!confirm(`Delete ${ids.length} selected users?`)) return;

    for (const id of ids) {
        await fetch(`${API_BASE}/users/${id}`, { method: 'DELETE' });
    }

    loadAllData();
};

window.deleteUser = async (id) => {
    if (!confirm('Delete this user?')) return;
    await fetch(`${API_BASE}/users/${id}`, { method: 'DELETE' });
    loadAllData();
};

// --- 3. Timetable ---

function formatTime12h(timeStr) {
    if (!timeStr) return '';
    let [hours, minutes] = timeStr.split(':');
    hours = parseInt(hours);
    const ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12; // the hour '0' should be '12'
    return `${hours}:${minutes} ${ampm}`;
}

function renderTimetable() {
    const tableBody = document.getElementById('tt-table-body');
    tableBody.innerHTML = '';

    if (!state.timetable) return;
    console.log('Timetable Data:', state.timetable.slice(0, 2));

    // Sorting Logic
    const dayOrder = { 'Monday': 1, 'Tuesday': 2, 'Wednesday': 3, 'Thursday': 4, 'Friday': 5, 'Saturday': 6, 'Sunday': 7 };
    
    const sortedTimetable = [...state.timetable].sort((a, b) => {
        // Take first day if multiple
        const firstDayA = (a.days || '').split(',')[0];
        const firstDayB = (b.days || '').split(',')[0];
        
        const dayA = dayOrder[firstDayA] || 99;
        const dayB = dayOrder[firstDayB] || 99;
        
        if (dayA !== dayB) return dayA - dayB;
        
        // Secondary sort: Start Time
        return (a.start_time || '').localeCompare(b.start_time || '');
    });

    sortedTimetable.forEach(t => {
        let rolesHtml = '<span class="text-muted">No users</span>';
        if (t.assigned_roles) {
            const roleCounts = {};
            t.assigned_roles.split(',').forEach(role => {
                if (role && role !== 'null') {
                    roleCounts[role] = (roleCounts[role] || 0) + 1;
                }
            });
            rolesHtml = `<div style="display: flex; flex-direction: column; gap: 4px; align-items: flex-start;">` + 
                Object.entries(roleCounts).map(([role, count]) => `
                    <div class="role-group-badge" style="display: inline-flex; align-items: center; background: rgba(255, 255, 255, 0.05); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 12px; padding: 3px 10px; font-size: 11px;">
                        <span style="margin-right: 8px; opacity: 0.9;">${role}</span>
                        <span style="background: #0078D4; color: white; border-radius: 50%; min-width: 18px; height: 18px; display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: bold;">${count}</span>
                    </div>
                `).join('') + `</div>`;
        }

        tableBody.innerHTML += `
            <tr id="tt-row-${t.id}">
                <td><span class="badge info">${t.days || 'N/A'}</span></td>
                <td style="max-width: 250px; white-space: normal;">${rolesHtml}</td>
                <td><small>${getFullDeptPath(t.dept_id)}</small></td>
                <td><strong>${t.activity_name}</strong></td>
                <td>
                    <div style="font-size: 13px;">${formatTime12h(t.start_time.slice(0, 5))} - ${formatTime12h(t.end_time.slice(0, 5))}</div>
                    <div class="text-muted" style="font-size: 11px;">${new Date(t.start_date).toLocaleDateString()} to ${new Date(t.end_date).toLocaleDateString()}</div>
                </td>
                <td class="action-cell">
                    <button class="btn-icon" onclick="editTimetableRow(${t.id})">
                        <span class="material-symbols-rounded">edit</span>
                    </button>
                    <button class="btn-icon text-danger" onclick="deleteTimetable(${t.id})">
                        <span class="material-symbols-rounded">delete</span>
                    </button>
                </td>
            </tr>
        `;
    });
}

window.deleteTimetable = async (id) => {
    if (!confirm('Delete this schedule entry?')) return;
    await fetch(`${API_BASE}/timetable/${id}`, { method: 'DELETE' });
    loadAllData();
};

window.editTimetableRow = (id) => {
    const t = state.timetable.find(item => item.id === id);
    const row = document.getElementById(`tt-row-${id}`);
    if (!t || !row) return;

    // Load existing users into picker state for this edit
    selectedPickerUsers = t.user_ids ? t.user_ids.split(',').map(uid => parseInt(uid)) : [];

    row.innerHTML = `
        <td>
            <select id="edit-tt-day-${id}" class="custom-input" style="font-size: 11px; height: 32px;">
                <option value="Monday" ${t.days === 'Monday' ? 'selected' : ''}>Mon</option>
                <option value="Tuesday" ${t.days === 'Tuesday' ? 'selected' : ''}>Tue</option>
                <option value="Wednesday" ${t.days === 'Wednesday' ? 'selected' : ''}>Wed</option>
                <option value="Thursday" ${t.days === 'Thursday' ? 'selected' : ''}>Thu</option>
                <option value="Friday" ${t.days === 'Friday' ? 'selected' : ''}>Fri</option>
                <option value="Saturday" ${t.days === 'Saturday' ? 'selected' : ''}>Sat</option>
                <option value="Sunday" ${t.days === 'Sunday' ? 'selected' : ''}>Sun</option>
            </select>
        </td>
        <td>
            <button class="btn-primary" style="font-size: 10px; padding: 5px 10px;" onclick="openPersonnelPicker()">
                Manage (${selectedPickerUsers.length})
            </button>
        </td>
        <td>
            <select id="edit-tt-dept-${id}" class="custom-input" style="font-size: 11px; height: 32px;">
                ${state.departments.map(d => `<option value="${d.id}" ${d.id === t.dept_id ? 'selected' : ''}>${d.name}</option>`).join('')}
            </select>
        </td>
        <td>
            <input type="text" id="edit-tt-name-${id}" class="custom-input" value="${t.activity_name}" style="font-size: 12px; height: 32px;">
        </td>
        <td>
            <div style="display: flex; flex-direction: column; gap: 4px;">
                <div style="display: flex; gap: 4px;">
                    <input type="time" id="edit-tt-start-val-${id}" class="custom-input" value="${t.start_time.slice(0, 5)}" style="font-size: 11px; height: 32px; flex: 1;">
                    <span style="opacity: 0.5; align-self: center;">-</span>
                    <input type="time" id="edit-tt-end-val-${id}" class="custom-input" value="${t.end_time.slice(0, 5)}" style="font-size: 11px; height: 32px; flex: 1;">
                </div>
                <div style="display: flex; gap: 4px;">
                    <input type="date" id="edit-tt-sdate-${id}" class="custom-input" value="${t.start_date.slice(0, 10)}" style="font-size: 10px; height: 24px; padding: 2px;">
                    <input type="date" id="edit-tt-edate-${id}" class="custom-input" value="${t.end_date.slice(0, 10)}" style="font-size: 10px; height: 24px; padding: 2px;">
                </div>
            </div>
        </td>
        <td class="action-cell">
            <button class="btn-icon text-success" onclick="saveTimetableEdit(${id})">
                <span class="material-symbols-rounded">check</span>
            </button>
            <button class="btn-icon" onclick="renderTimetable()">
                <span class="material-symbols-rounded">close</span>
            </button>
        </td>
    `;
};

window.saveTimetableEdit = async (id) => {
    const payload = {
        activity_name: document.getElementById(`edit-tt-name-${id}`).value,
        start_time: document.getElementById(`edit-tt-start-val-${id}`).value + ':00',
        end_time: document.getElementById(`edit-tt-end-val-${id}`).value + ':00',
        start_date: document.getElementById(`edit-tt-sdate-${id}`).value,
        end_date: document.getElementById(`edit-tt-edate-${id}`).value,
        dept_id: document.getElementById(`edit-tt-dept-${id}`).value,
        days: [document.getElementById(`edit-tt-day-${id}`).value],
        user_ids: selectedPickerUsers
    };

    await fetch(`${API_BASE}/timetable/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
    
    selectedPickerUsers = [];
    loadAllData();
};

window.openPersonnelPicker = () => {
    // Populate Role filter
    const roles = state.roles.map(r => r.name);
    const roleSelect = document.getElementById('picker-filter-role');
    if (roleSelect) {
        roleSelect.innerHTML = '<option value="">All Roles</option>' + roles.map(r => `<option value="${r}">${r}</option>`).join('');
    }

    // Populate Dept filter
    const deptSelect = document.getElementById('picker-filter-dept');
    if (deptSelect) {
        deptSelect.innerHTML = '<option value="">All Departments</option>' + state.departments.map(d => `<option value="${d.id}">${d.name}</option>`).join('');
    }

    // Attach filter events
    ['picker-search-name', 'picker-filter-role', 'picker-filter-dept'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.oninput = renderPersonnelPicker;
    });

    renderPersonnelPicker();
    document.getElementById('personnel-picker-modal').style.display = 'flex';
};

function renderPersonnelPicker() {
    const search = document.getElementById('picker-search-name').value.toLowerCase();
    const role = document.getElementById('picker-filter-role').value;
    const dept = document.getElementById('picker-filter-dept').value;

    const list = document.getElementById('picker-user-list');
    list.innerHTML = '';

    const filtered = state.users.filter(u => {
        const matchesSearch = u.full_name.toLowerCase().includes(search) || (u.email && u.email.toLowerCase().includes(search));
        const matchesRole = !role || u.role === role;
        const matchesDept = !dept || u.dept_id == dept;
        return matchesSearch && matchesRole && matchesDept;
    });

    const countDisplay = document.getElementById('picker-count-display');
    if (countDisplay) countDisplay.innerText = `${filtered.length} users found`;

    const selectAllBtn = document.getElementById('btn-picker-select-all');
    if (selectAllBtn) {
        const allSelected = filtered.length > 0 && filtered.every(u => selectedPickerUsers.includes(u.id));
        selectAllBtn.innerText = allSelected ? 'Deselect All' : 'Select All';
    }

    if (filtered.length === 0) {
        list.innerHTML = '<div class="p-20 text-muted" style="text-align: center;">No matching staff found.</div>';
    }

    filtered.forEach(u => {
        const isSelected = selectedPickerUsers.includes(u.id);
        const initialsHtml = `<div class="student-initial" style="width: 32px; height: 32px; font-size: 11px; flex-shrink: 0;">${u.full_name.charAt(0)}</div>`;
        const avatarHtml = u.image_url 
            ? `<img src="${API_BASE.replace('/api', '')}${u.image_url}" 
                 style="width: 32px; height: 32px; border-radius: 50%; object-fit: cover; border: 1px solid rgba(255,255,255,0.1); flex-shrink: 0;"
                 onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';">
               <div class="student-initial" style="width: 32px; height: 32px; font-size: 11px; display: none; flex-shrink: 0;">${u.full_name.charAt(0)}</div>`
            : initialsHtml;

        list.innerHTML += `
            <div class="personnel-item" style="display: flex; align-items: center; gap: 15px; padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.05);">
                <input type="checkbox" class="picker-checkbox" value="${u.id}" ${isSelected ? 'checked' : ''} 
                    onchange="togglePickerUser(${u.id}, this.checked)"
                    style="width: 18px; height: 18px; cursor: pointer;">
                ${avatarHtml}
                <div style="flex: 1;">
                    <div style="font-weight: 500; font-size: 14px;">${u.full_name}</div>
                    <div class="text-muted" style="font-size: 11px;">${getFullDeptPath(u.dept_id)} • ${u.role || 'No Role'}</div>
                </div>
            </div>
        `;
    });
}

window.togglePickerUser = (id, checked) => {
    if (checked) {
        if (!selectedPickerUsers.includes(id)) selectedPickerUsers.push(id);
    } else {
        selectedPickerUsers = selectedPickerUsers.filter(uid => uid !== id);
    }
};

// --- 4. Attendance Logs ---

// --- 4. Attendance Analysis & Logs ---

function populateNodeDropdown() {
    const select = document.getElementById('analysis-node');
    if (!select) return;

    const currentVal = select.value;
    // Only show nodes that actually have activities/schedules
    const nodesWithSchedules = new Set(state.timetable.map(t => t.dept_id));
    const activeNodes = state.departments.filter(d => nodesWithSchedules.has(d.id));

    select.innerHTML = '<option value="">All Nodes</option>' + 
        activeNodes.map(d => `<option value="${d.id}" ${d.id == currentVal ? 'selected' : ''}>${d.name}</option>`).join('');
}

function populateActivityDropdown() {
    const activitySelect = document.getElementById('analysis-activity');
    const nodeSelect = document.getElementById('analysis-node');
    if (!activitySelect) return;

    const nodeId = nodeSelect?.value;
    const currentActivityVal = activitySelect.value;

    let filteredActivities = state.activities;
    if (nodeId) {
        const nodeSchedules = state.timetable.filter(t => t.dept_id == nodeId);
        const nodeActivityNames = new Set(nodeSchedules.map(t => t.activity_name));
        filteredActivities = state.activities.filter(a => nodeActivityNames.has(a.name));
    }

    const uniqueMap = new Map();
    filteredActivities.forEach(a => {
        if (!uniqueMap.has(a.name)) {
            uniqueMap.set(a.name, a);
        }
    });
    const uniqueActivities = Array.from(uniqueMap.values());

    activitySelect.innerHTML = '<option value="">Select Activity...</option>' + 
        uniqueActivities.map(a => `<option value="${a.id}" ${a.id == currentActivityVal ? 'selected' : ''}>${a.name}</option>`).join('');
}

function initAttendanceLogsView() {
    // Populate dropdowns
    populateNodeDropdown();
    populateActivityDropdown();

    const activitySelect = document.getElementById('analysis-activity');
    const nodeSelect = document.getElementById('analysis-node');

    // If nothing selected, pick the first available combination
    if (activitySelect && !activitySelect.value && state.activities.length > 0) {
        const firstActivity = state.activities[0];
        
        // Find a node that has this activity
        const schedule = state.timetable.find(t => t.activity_name === firstActivity.name);
        if (schedule) {
            if (nodeSelect) nodeSelect.value = schedule.dept_id;
            // Re-populate activity dropdown based on this node to ensure it's there
            populateActivityDropdown();
            activitySelect.value = firstActivity.id;
        } else {
            activitySelect.value = firstActivity.id;
        }
    }
    
    renderAttendanceLogs();
    renderUploadPermissions();
}

async function renderAttendanceLogs() {
    // This now refers to the Student Attendance Grid
    const activityId = document.getElementById('analysis-activity')?.value;
    const nodeId = document.getElementById('analysis-node')?.value;
    const grid = document.getElementById('student-attendance-grid');
    if (!grid) return;

    if (!activityId) {
        grid.innerHTML = '<div class="loading-text" style="grid-column: 1 / -1;">Select an activity to view attendance analysis.</div>';
        return;
    }

    grid.innerHTML = '<div class="loading-text" style="grid-column: 1 / -1;">Calculating performance metrics...</div>';

    try {
        const activity = state.activities.find(a => a.id == activityId);
        if (!activity) return;

        // Filter schedules by activity name and node if selected
        let activitySchedules = state.timetable.filter(t => t.activity_name === activity.name);
        if (nodeId) {
            activitySchedules = activitySchedules.filter(t => t.dept_id == nodeId);
        }
        
        // Find users assigned to this activity in the selected node(s)
        let assignedUserIds = new Set();
        activitySchedules.forEach(s => {
            if (s.user_ids) s.user_ids.split(',').forEach(id => assignedUserIds.add(parseInt(id)));
        });

        const users = state.users.filter(u => assignedUserIds.has(u.id));
        
        if (users.length === 0) {
            grid.innerHTML = '<div class="loading-text" style="grid-column: 1 / -1;">No personnel assigned to this activity in the selected context.</div>';
            return;
        }

        let html = '';
        users.forEach(u => {
            const userLogs = state.attendance.filter(log => log.user_id === u.id && log.activity_name === activity.name);
            const totalSessions = 10; // Mock
            const present = userLogs.length;
            const percentage = ((present / totalSessions) * 100);
            const pctStr = percentage.toFixed(1);

            const initialsHtml = `<div class="student-initial">${u.full_name.charAt(0)}</div>`;
            const avatarHtml = u.image_url 
                ? `<img src="${API_BASE.replace('/api', '')}${u.image_url}" 
                     class="student-initial" style="object-fit: cover;"
                     onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';">
                   <div class="student-initial" style="display: none;">${u.full_name.charAt(0)}</div>`
                : initialsHtml;

            html += `
                <div class="student-card" onclick="openUserAnalytics(${u.id}, ${activityId})" style="cursor: pointer;">
                    <div style="position: relative; width: 44px; height: 44px; display: flex; align-items: center; justify-content: center;">
                        ${avatarHtml}
                    </div>
                    <div class="student-info">
                        <span class="student-name">${u.full_name}</span>
                        <span class="student-role">${u.role || 'Personnel'}</span>
                    </div>
                    <div class="pct-badge ${percentage < 50 ? 'danger' : ''}">${pctStr}%</div>
                </div>
            `;
        });
        grid.innerHTML = html;

    } catch (e) {
        grid.innerHTML = `<div class="loading-text" style="grid-column: 1 / -1; color: var(--danger);">Error: ${e.message}</div>`;
    }
}

async function generateAttendanceReport() {
    const activityId = document.getElementById('analysis-activity')?.value;
    const nodeId = document.getElementById('analysis-node')?.value;
    
    if (!activityId) return alert('Please select an activity first.');
    
    const activity = state.activities.find(a => a.id == activityId);
    const node = state.departments.find(d => d.id == nodeId);
    
    const { jsPDF } = window.jspdf;
    const doc = new jsPDF();
    
    // Header - More Compact
    doc.setFontSize(16);
    doc.setTextColor(99, 102, 241); 
    doc.text('Attendance Analytics Report', 15, 20);
    
    doc.setFontSize(9);
    doc.setTextColor(100, 116, 139);
    doc.text(`Generated: ${new Date().toLocaleString()}`, 15, 26);
    
    // Metadata Panel - More Compact
    doc.setFillColor(248, 250, 252);
    doc.rect(15, 32, 180, 15, 'F');
    
    doc.setFontSize(10);
    doc.setTextColor(15, 23, 42);
    doc.setFont(undefined, 'bold');
    doc.text('Activity:', 20, 42);
    doc.text('Node:', 100, 42);
    
    doc.setFont(undefined, 'normal');
    doc.text(activity.name, 40, 42);
    doc.text(node ? node.name : 'All Nodes', 115, 42);
    
    // Table Calculation
    let activitySchedules = state.timetable.filter(t => t.activity_name === activity.name);
    if (nodeId) activitySchedules = activitySchedules.filter(t => t.dept_id == nodeId);
    
    let assignedUserIds = new Set();
    activitySchedules.forEach(s => {
        if (s.user_ids) s.user_ids.split(',').forEach(id => assignedUserIds.add(parseInt(id)));
    });

    const users = state.users.filter(u => assignedUserIds.has(u.id));
    
    const tableData = users.map((u, index) => {
        const userLogs = state.attendance.filter(log => log.user_id === u.id && log.activity_name === activity.name);
        const totalSessions = 10; // Mock
        const present = userLogs.length;
        const percentage = ((present / totalSessions) * 100).toFixed(1);
        return [index + 1, u.full_name, u.role || 'Personnel', `${present}/${totalSessions}`, `${percentage}%`];
    });
    
    doc.autoTable({
        startY: 55,
        margin: { left: 15, right: 15 },
        head: [['Sl No', 'Name', 'Role', 'Count', 'Attendance Percentage']],
        body: tableData,
        theme: 'striped',
        headStyles: { fillColor: [99, 102, 241], fontSize: 9, cellPadding: 2, halign: 'left' },
        styles: { fontSize: 8.5, cellPadding: 2.5, overflow: 'linebreak' },
        columnStyles: {
            0: { halign: 'center', cellWidth: 15 },
            3: { halign: 'center' },
            4: { halign: 'right', fontStyle: 'bold' }
        },
        didParseCell: function (data) {
            if (data.section === 'head' && data.column.index === 4) {
                data.cell.styles.halign = 'right';
            }
        },
        alternateRowStyles: { fillColor: [250, 250, 250] }
    });
    
    doc.save(`Attendance_Report_${activity.name.replace(/\s+/g, '_')}.pdf`);
}

window.openUserAnalytics = (userId, initialActivityId) => {
    const user = state.users.find(u => u.id === userId);
    if (!user) return;

    document.getElementById('user-analytics-name').innerText = user.full_name;
    document.getElementById('user-analytics-role').innerText = user.role || 'Personnel';
    
    const initialBox = document.getElementById('user-analytics-initial');
    if (user.image_url) {
        initialBox.innerHTML = `
            <img src="${API_BASE.replace('/api', '')}${user.image_url}" 
                 style="width: 100%; height: 100%; border-radius: 50%; object-fit: cover;"
                 onerror="this.style.display='none'; this.parentElement.innerText='${user.full_name.charAt(0)}'; this.parentElement.style.background='rgba(255, 255, 255, 0.1)';">
        `;
        initialBox.style.background = 'transparent';
        initialBox.style.border = '1px solid var(--glass-border)';
    } else {
        initialBox.innerText = user.full_name.charAt(0);
        initialBox.style.background = 'rgba(255, 255, 255, 0.1)';
        initialBox.style.display = 'flex'; // Ensure it's showing
    }

    // Populate Subject Selector
    const userSchedules = state.timetable.filter(t => t.user_ids && t.user_ids.split(',').includes(userId.toString()));
    const userActivityNames = [...new Set(userSchedules.map(t => t.activity_name))];
    const userActivities = state.activities.filter(a => userActivityNames.includes(a.name));

    const subjectSelect = document.getElementById('user-analytics-subject-select');
    subjectSelect.innerHTML = userActivities.map(a => `
        <option value="${a.id}" ${a.id == initialActivityId ? 'selected' : ''}>${a.name}</option>
    `).join('');

    subjectSelect.onchange = (e) => renderUserAnalyticsLogs(userId, e.target.value);

    // Report Button
    const btnReport = document.getElementById('btn-user-report');
    if (btnReport) {
        btnReport.onclick = () => generateIndividualReport(userId, subjectSelect.value);
    }

    renderUserAnalyticsLogs(userId, initialActivityId);
    document.getElementById('user-analytics-modal').style.display = 'flex';
};

function parseDBDate(dateStr) {
    if (!dateStr) return new Date();
    // Replace space with T to make it ISO compatible if needed
    const isoStr = dateStr.includes(' ') ? dateStr.replace(' ', 'T') : dateStr;
    const d = new Date(isoStr);
    return isNaN(d.getTime()) ? new Date() : d;
}

function getEnrolledActivityDates(activityName) {
    // Get all records for this activity
    const allActivityLogs = state.attendance.filter(log => log.activity_name === activityName);
    
    // Group by unique (date + time_range)
    const sessions = [];
    const seen = new Set();
    
    allActivityLogs.forEach(log => {
        const d = parseDBDate(log.date || log.created_at);
        const dateStr = d.toDateString();
        const timeRange = `${parse24h(log.start_time).time} ${parse24h(log.start_time).ampm} - ${parse24h(log.end_time).time} ${parse24h(log.end_time).ampm}`;
        const key = `${dateStr}_${timeRange}`;
        
        if (!seen.has(key)) {
            seen.add(key);
            sessions.push({
                date: d,
                dateStr: dateStr,
                timeRange: timeRange,
                startTimeRaw: log.start_time
            });
        }
    });
    
    // Sort Ascending by Date then Time
    return sessions.sort((a, b) => {
        if (a.date.getTime() !== b.date.getTime()) return a.date.getTime() - b.date.getTime();
        return a.startTimeRaw.localeCompare(b.startTimeRaw);
    });
}
function renderUserAnalyticsLogs(userId, activityId) {
    const logsContainer = document.getElementById('user-analytics-logs');
    const activity = state.activities.find(a => a.id == activityId);
    if (!activity) return;

    const activitySessions = getEnrolledActivityDates(activity.name);
    const userLogs = state.attendance.filter(log => log.user_id === userId && log.activity_name === activity.name);
    
    if (activitySessions.length === 0) {
        logsContainer.innerHTML = '<div class="loading-text" style="grid-column: 1 / -1;">No attendance records found for this activity yet.</div>';
        return;
    }

    let html = '';
    activitySessions.forEach(session => {
        const log = userLogs.find(l => {
            const ld = parseDBDate(l.date || l.created_at).toDateString();
            const lt = `${parse24h(l.start_time).time} ${parse24h(l.start_time).ampm} - ${parse24h(l.end_time).time} ${parse24h(l.end_time).ampm}`;
            return ld === session.dateStr && lt === session.timeRange;
        });
        const isPresent = !!log;
        
        html += `
            <div class="session-status-card ${isPresent ? 'present' : 'absent'}">
                <span class="date-text">${session.date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}</span>
                <div style="display: flex; align-items: center; justify-content: center; gap: 4px; font-size: 11px; font-weight: 700; color: ${isPresent ? 'var(--success)' : 'var(--danger)'};">
                    <span class="status-dot ${isPresent ? 'present' : 'absent'}"></span>
                    ${isPresent ? 'PRESENT' : 'ABSENT'}
                </div>
                <div style="font-size: 10px; color: var(--text-muted); margin-top: 5px;">${session.timeRange}</div>
                ${isPresent && (log.entry_time || log.exit_time) ? `
                    <div style="margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(255,255,255,0.05); font-size: 10px; display: flex; flex-direction: column; gap: 2px;">
                        ${log.entry_time ? `<div style="color: var(--success); opacity: 0.8;">In: ${log.entry_time.substring(0, 5)}</div>` : ''}
                        ${log.exit_time ? `<div style="color: var(--warning); opacity: 0.8;">Out: ${log.exit_time.substring(0, 5)}</div>` : ''}
                    </div>
                ` : ''}
            </div>
        `;
    });
    logsContainer.innerHTML = html;
}


async function generateIndividualReport(userId, _) {
    const user = state.users.find(u => u.id === userId);
    if (!user) return;

    // Get all activities this user is assigned to
    const userSchedules = state.timetable.filter(t => t.user_ids && t.user_ids.split(',').includes(userId.toString()));
    const uniqueNames = [...new Set(userSchedules.map(t => t.activity_name))];
    const userActivities = [];
    const seen = new Set();
    state.activities.forEach(a => {
        if (uniqueNames.includes(a.name) && !seen.has(a.name)) {
            userActivities.push(a);
            seen.add(a.name);
        }
    });

    // Calculate Overall Stats
    let totalOverallSessions = 0;
    let totalOverallPresent = 0;
    userActivities.forEach(activity => {
        const activityDates = getEnrolledActivityDates(activity.name);
        const userLogs = state.attendance.filter(log => log.user_id === userId && log.activity_name === activity.name);
        totalOverallSessions += activityDates.length;
        totalOverallPresent += userLogs.length;
    });
    const overallPercentage = totalOverallSessions > 0 ? ((totalOverallPresent / totalOverallSessions) * 100).toFixed(1) : "0.0";

    const { jsPDF } = window.jspdf;
    const doc = new jsPDF();
    let currentY = 30;

    // Page Header
    doc.setFontSize(22);
    doc.setTextColor(99, 102, 241);
    doc.text('Individual Attendance Dashboard', 15, currentY);
    currentY += 10;

    doc.setFontSize(11);
    doc.setTextColor(100, 116, 139);
    doc.text(`Personnel: ${user.full_name} | Role: ${user.role || 'Personnel'}`, 15, currentY);
    currentY += 6;
    doc.setFont(undefined, 'bold');
    doc.setTextColor(15, 23, 42);
    doc.text(`Overall Attendance: ${overallPercentage}% (${totalOverallPresent}/${totalOverallSessions})`, 15, currentY);
    doc.setFont(undefined, 'normal');
    currentY += 6;
    doc.setTextColor(100, 116, 139);
    doc.text(`Generated: ${new Date().toLocaleString()}`, 15, currentY);
    currentY += 15;

    for (const activity of userActivities) {
        const sessions = getEnrolledActivityDates(activity.name);
        const userLogs = state.attendance.filter(log => log.user_id === userId && log.activity_name === activity.name);

        if (sessions.length === 0) continue;

        const activityPresent = userLogs.length;
        const activityTotal = sessions.length;
        const activityPercentage = ((activityPresent / activityTotal) * 100).toFixed(1);

        // Check for page overflow
        if (currentY > 230) {
            doc.addPage();
            currentY = 20;
        }

        // Activity Header
        doc.setFillColor(248, 250, 252);
        doc.rect(15, currentY, 180, 10, 'F');
        doc.setFontSize(12);
        doc.setTextColor(15, 23, 42);
        doc.setFont(undefined, 'bold');
        doc.text(activity.name, 20, currentY + 7);
        
        // Activity Stats aside heading
        doc.setFontSize(10);
        doc.setTextColor(71, 85, 105);
        doc.text(`${activityPercentage}% (${activityPresent}/${activityTotal})`, 190, currentY + 7, { align: 'right' });
        
        currentY += 15;

        // Grid Configuration
        const boxWidth = 33;
        const boxHeight = 16;
        const spacing = 4;
        const boxesPerRow = 5;
        let xPos = 15;

        doc.setFontSize(7);
        doc.setFont(undefined, 'normal');

        sessions.forEach((session, index) => {
            if (index > 0 && index % boxesPerRow === 0) {
                xPos = 15;
                currentY += boxHeight + spacing;
                
                // Check for page overflow within activity grid
                if (currentY > 260) {
                    doc.addPage();
                    currentY = 20;
                }
            }

            const log = userLogs.find(l => {
                const ld = parseDBDate(l.date || l.created_at).toDateString();
                const lt = `${parse24h(l.start_time).time} ${parse24h(l.start_time).ampm} - ${parse24h(l.end_time).time} ${parse24h(l.end_time).ampm}`;
                return ld === session.dateStr && lt === session.timeRange;
            });
            const isPresent = !!log;

            // Draw Box
            doc.setDrawColor(226, 232, 240);
            doc.setFillColor(isPresent ? 236 : 254, isPresent ? 253 : 242, isPresent ? 245 : 242); // Light Green/Red
            doc.rect(xPos, currentY, boxWidth, boxHeight, 'FD');

            // Status indicator line
            doc.setDrawColor(isPresent ? 16 : 239, isPresent ? 185 : 68, isPresent ? 129 : 68);
            doc.setLineWidth(1);
            doc.line(xPos, currentY + boxHeight, xPos + boxWidth, currentY + boxHeight);
            doc.setLineWidth(0.1);

            // Date Text
            doc.setTextColor(15, 23, 42);
            doc.setFont(undefined, 'bold');
            doc.text(session.date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }), xPos + 2, currentY + 5);
            
            // Status/Time Text
            doc.setFont(undefined, 'normal');
            doc.setTextColor(isPresent ? 16 : 239, isPresent ? 185 : 68, isPresent ? 129 : 68);
            doc.text(isPresent ? 'PRESENT' : 'ABSENT', xPos + 2, currentY + 10);
            
            doc.setTextColor(100, 116, 139);
            if (isPresent && (log.entry_time || log.exit_time)) {
                let times = [];
                if (log.entry_time) times.push(`In: ${log.entry_time.substring(0, 5)}`);
                if (log.exit_time) times.push(`Out: ${log.exit_time.substring(0, 5)}`);
                doc.text(times.join(' | '), xPos + 2, currentY + 14);
            } else {
                doc.text(session.timeRange, xPos + 2, currentY + 14);
            }

            xPos += boxWidth + spacing;
        });

        currentY += boxHeight + 20; // Space after activity grid
    }

    doc.save(`Attendance_Dashboard_${user.full_name.replace(/\s+/g, '_')}.pdf`);
}

function renderUploadPermissions() {
    const rolesContainer = document.getElementById('roles-checkbox-container');
    const usersContainer = document.getElementById('users-selected-container');
    if (!rolesContainer || !usersContainer) return;

    // Roles
    const roles = state.roles.map(r => r.name);
    const roleAuths = roles.map(role => {
        const usersInRole = state.users.filter(u => u.role === role);
        return usersInRole.length > 0 && usersInRole.every(u => u.can_upload);
    });
    
    rolesContainer.innerHTML = roles.map((role, idx) => {
        return `
            <div style="display: flex; align-items: center; justify-content: space-between; padding: 5px 0;">
                <span style="font-size: 14px; color: var(--text-main); font-weight: 500;">${role}</span>
                <input type="checkbox" class="custom-checkbox" onchange="toggleRoleUploadPermission('${role}', this.checked)" ${roleAuths[idx] ? 'checked' : ''} style="width: 18px; height: 18px;">
            </div>
        `;
    }).join('');

    // Users
    const authUsers = state.users.filter(u => u.can_upload);
    usersContainer.innerHTML = authUsers.length ? authUsers.map(u => {
        const avatarSrc = u.image_url ? `${API_BASE.replace('/api', '')}${u.image_url}` : null;
        return `
            <div class="chip" style="padding-left: 5px;">
                ${avatarSrc ? `<img src="${avatarSrc}" style="width: 20px; height: 20px; border-radius: 50%; margin-right: 8px; object-fit: cover;">` : ''}
                <span>${u.full_name}</span>
                <span class="material-symbols-rounded remove-btn" onclick="toggleUserUploadPermission(${u.id}, false)">close</span>
            </div>
        `;
    }).join('') : '<div class="text-muted" style="font-size: 13px; text-align: center; width: 100%; padding-top: 50px;">No specific users assigned.</div>';
}

window.toggleUserUploadPermission = async (userId, status) => {
    const u = state.users.find(user => user.id === userId);
    if (!u) return;

    await fetch(`${API_BASE}/users/${userId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ 
            ...u, 
            can_upload: status ? 1 : 0 
        })
    });
    loadAllData();
};

window.toggleRoleUploadPermission = async (role, status) => {
    const usersInRole = state.users.filter(u => u.role === role);
    for (const u of usersInRole) {
        await fetch(`${API_BASE}/users/${u.id}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ...u, can_upload: status ? 1 : 0 })
        });
    }
    loadAllData();
};

// --- Selectors & Interaction ---

function populateSelectors() {
    const assignTree = document.getElementById('assign-subdept-tree');
    if (assignTree) {
        assignTree.innerHTML = buildTreeHTML(null, 'assign');
    }

    const ttTree = document.getElementById('tt-subdept-tree');
    if (ttTree) {
        ttTree.innerHTML = buildTreeHTML(null, 'tt');
    }
}

function buildTreeHTML(parentId, context = 'assign') {
    // Filter logic: if parentId is null/undefined, find roots (!d.parent_id). Otherwise match exactly.
    const children = state.departments.filter(d => {
        if (parentId === null || parentId === undefined || parentId === '') {
            return !d.parent_id;
        }
        return d.parent_id == parentId;
    });

    if (children.length === 0) return '';

    let html = '<ul>';
    children.forEach(child => {
        html += `
            <li onclick="event.stopPropagation(); selectNode(${child.id}, '${child.name}', '${context}')" class="${child.status ? '' : 'inactive-dept'}">
                <div style="display: flex; align-items: center; gap: 8px;">
                    <span>${child.name}</span>
                    ${!child.status ? '<span class="material-symbols-rounded" style="font-size: 14px; color: var(--danger);">close</span>' : ''}
                </div>
                ${buildTreeHTML(child.id, context)}
            </li>
        `;
    });
    html += '</ul>';
    return html;
}

window.selectNode = (id, name, context = 'assign') => {
    if (context === 'explorer') {
        openNodeExplorer(id);
        return;
    }

    const prefix = context === 'tt' ? 'tt' : 'assign';
    document.getElementById(`${prefix}-subdept-select`).value = id;
    document.getElementById(`${prefix}-subdept-display`).innerText = name;
    document.getElementById(`${prefix}-subdept-display`).classList.remove('text-muted');
    document.getElementById(`${prefix}-subdept-dropdown`).style.display = 'none';
};

function setupEventListeners() {
    // Theme Toggle
    const themeContainer = document.querySelector('.theme-toggle-container');
    if (themeContainer) {
        themeContainer.onclick = () => toggleTheme();
    }

    // Tab switching
    document.querySelectorAll('.nav-links li').forEach(li => {
        li.onclick = () => {
            document.querySelectorAll('.nav-links li').forEach(l => l.classList.remove('active'));
            document.querySelectorAll('.content-section').forEach(s => s.classList.remove('active'));
            li.classList.add('active');
            document.getElementById(li.dataset.tab).classList.add('active');

            if (li.dataset.tab === 'attendance-logs') {
                initAttendanceLogsView();
            }
        };
    });

    // Dropdown triggers
    ['assign', 'tt'].forEach(prefix => {
        const trigger = document.getElementById(`${prefix}-subdept-trigger`);
        if (trigger) {
            trigger.onclick = () => {
                const dd = document.getElementById(`${prefix}-subdept-dropdown`);
                dd.style.display = dd.style.display === 'none' ? 'block' : 'none';
            };
        }
    });

    // Add Department
    document.getElementById('overview-btn-add-dept').onclick = async () => {
        const name = document.getElementById('overview-new-dept').value;
        if (!name) return;
        await apiPost('/departments', { name });
        document.getElementById('overview-new-dept').value = '';
        loadAllData();
    };

    // Bulk Deploy
    document.getElementById('btn-bulk-deploy').onclick = async () => {
        const deptId = document.getElementById('assign-subdept-select').value;
        const role = document.getElementById('assign-role-input').value;
        const data = document.getElementById('bulk-personnel-data').value;

        if (!deptId || !data) return alert('Please select a department and enter user data.');

        const lines = data.split('\n');
        for (const line of lines) {
            const [name, email] = line.split(',').map(s => s.trim());
            if (name && email) {
                await apiPost('/users', { full_name: name, email, role, dept_id: deptId });
            }
        }
        loadAllData();
    };

    // Refresh
    document.getElementById('refresh-btn').onclick = () => loadAllData();

    // Assignment Filter
    const filterInput = document.getElementById('assignment-name-filter');
    if (filterInput) {
        filterInput.oninput = () => renderUserAssignments();
    }

    // --- Timetable Events ---

    // Open Picker
    const btnOpenPicker = document.getElementById('btn-open-personnel-picker');
    if (btnOpenPicker) {
        btnOpenPicker.onclick = () => openPersonnelPicker();
    }

    // Close Picker
    const btnClosePicker = document.getElementById('btn-close-picker');
    if (btnClosePicker) {
        btnClosePicker.onclick = () => {
            document.getElementById('personnel-picker-modal').style.display = 'none';
        };
    }

    // Select All in Picker
    const btnPickerSelectAll = document.getElementById('btn-picker-select-all');
    if (btnPickerSelectAll) {
        btnPickerSelectAll.onclick = () => {
            const search = document.getElementById('picker-search-name').value.toLowerCase();
            const role = document.getElementById('picker-filter-role').value;
            const dept = document.getElementById('picker-filter-dept').value;

            const filtered = state.users.filter(u => {
                const matchesSearch = u.full_name.toLowerCase().includes(search) || (u.email && u.email.toLowerCase().includes(search));
                const matchesRole = !role || u.role === role;
                const matchesDept = !dept || u.dept_id == dept;
                return matchesSearch && matchesRole && matchesDept;
            });

            const allSelected = filtered.length > 0 && filtered.every(u => selectedPickerUsers.includes(u.id));

            if (allSelected) {
                const filteredIds = filtered.map(u => u.id);
                selectedPickerUsers = selectedPickerUsers.filter(id => !filteredIds.includes(id));
            } else {
                filtered.forEach(u => {
                    if (!selectedPickerUsers.includes(u.id)) selectedPickerUsers.push(u.id);
                });
            }
            renderPersonnelPicker();
        };
    }

    // Confirm Picker
    const btnConfirmPicker = document.getElementById('btn-confirm-picker');
    if (btnConfirmPicker) {
        btnConfirmPicker.onclick = async () => {
            if (window.pickerContext === 'permissions') {
                // Bulk update users
                for (const u of state.users) {
                    const shouldHavePerm = selectedPickerUsers.includes(u.id);
                    const currentPerm = u.can_upload ? 1 : 0;
                    if (currentPerm != (shouldHavePerm ? 1 : 0)) {
                        await fetch(`${API_BASE}/users/${u.id}`, {
                            method: 'PUT',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ ...u, can_upload: shouldHavePerm ? 1 : 0 })
                        });
                    }
                }
                window.pickerContext = null;
                loadAllData();
                document.getElementById('personnel-picker-modal').style.display = 'none';
                return;
            }

            const countDisplay = document.getElementById('selected-user-count');
            countDisplay.innerText = `${selectedPickerUsers.length} Selected`;
            countDisplay.style.display = selectedPickerUsers.length > 0 ? 'inline-block' : 'none';

            // Update any active "Manage" button in the table
            const activeManageBtn = document.querySelector('tr[id^="tt-row-"] button[onclick="openPersonnelPicker()"]');
            if (activeManageBtn) {
                activeManageBtn.innerText = `Manage (${selectedPickerUsers.length})`;
            }

            document.getElementById('personnel-picker-modal').style.display = 'none';
        };
    }

    // Add Timetable
    const btnAddTT = document.getElementById('btn-add-tt');
    if (btnAddTT) {
        btnAddTT.onclick = async () => {
            const deptId = document.getElementById('tt-subdept-select').value;
            const opName = document.getElementById('tt-operation-name').value;
            const startTimeVal = document.getElementById('tt-start-time').value;
            const endTimeVal = document.getElementById('tt-end-time').value;
            const startDate = document.getElementById('tt-start-date').value;
            const endDate = document.getElementById('tt-end-date').value;
            const day = document.getElementById('tt-day-select').value;

            if (!deptId || !opName || !startTimeVal || !endTimeVal || !startDate || !endDate) {
                return alert('Please fill in all operational parameters.');
            }

            if (selectedPickerUsers.length === 0) {
                return alert('Please assign at least one personnel to this operation.');
            }

            const payload = {
                activity_name: opName,
                start_time: startTimeVal + ':00',
                end_time: endTimeVal + ':00',
                start_date: startDate,
                end_date: endDate,
                dept_id: deptId,
                days: [day],
                user_ids: selectedPickerUsers
            };

            await apiPost('/timetable', payload);

            // Reset Form
            selectedPickerUsers = [];
            document.getElementById('selected-user-count').style.display = 'none';
            document.getElementById('tt-operation-name').value = '';

            loadAllData();
            alert('Operation committed to master schedule.');
        };
    }

    // --- Attendance Events ---
    const btnOpenPermPicker = document.getElementById('btn-open-user-permissions-picker');
    if (btnOpenPermPicker) {
        btnOpenPermPicker.onclick = () => {
            window.pickerContext = 'permissions';
            selectedPickerUsers = state.users.filter(u => u.can_upload).map(u => u.id);
            window.openPersonnelPicker();
        };
    }

    const analysisActivity = document.getElementById('analysis-activity');
    if (analysisActivity) {
        analysisActivity.onchange = () => renderAttendanceLogs();
    }
    const analysisNode = document.getElementById('analysis-node');
    if (analysisNode) {
        analysisNode.onchange = () => {
            populateActivityDropdown();
            renderAttendanceLogs();
        };
    }

    const btnMakeReport = document.getElementById('btn-make-report');
    if (btnMakeReport) {
        btnMakeReport.onclick = () => generateAttendanceReport();
    }
}
