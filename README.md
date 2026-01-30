# 🚦 Environmental project MTA:SA dynamic traffic system

![MTA:SA Version](https://img.shields.io/badge/MTA%3ASA-1.6%2B-blue.svg)
![License](https://img.shields.io/badge/License-CC%20BY--NC%204.0-orange.svg)

**Environmental project** is a high-performance, scalable, and intelligent NPC traffic system designed for Multi Theft Auto: San Andreas. Built on top of the robust `npc_hlc` library, it introduces modern features like dynamic density, cluster-based spawning, and smart deadlock resolution to support servers with high player counts (500+).

---

## ✨ Key Features

### 🚀 Scalability & Performance
The system is engineered to run smoothly on populated servers:
- **Dynamic Density**: Automatically adjusts traffic volume based on total player count (e.g., 100% density at 10 players, down to 15% at 500+ players).
- **Cluster Detection**: Groups nearby players into "clusters" (150m radius). Only the cluster owner spawns traffic, which is then shared visually with others, preventing duplicate entities and reducing server load.
- **Smart Despawn**: Aggressive cleanup of distant vehicles and NPCs that are no longer relevant to any player.
- **Anti-AFK System**: Prevents AFK players from accumulating traffic resources, cleaning up their surroundings after 5 seconds of inactivity.

### 🧠 Advanced AI Behavior
- **Speed Personality**: Every NPC has a unique driving style with speed variations (±15%), making traffic flow feel natural and organic.
- **Lane Discipline**: NPCs generally stick to lanes but can react to immediate threats.
- **Collision Avoidance**: Uses `npc_sensors` with advanced raycasting to detect obstacles (vehicles, players, objects) and brake or swerve accordingly.
- **Deadlock Resolution**: Automatically detects head-on collisions or gridlocks and resolves them by reversing vehicles or, in worst-case scenarios, fading them out.
- **Frustration System**: NPCs that remain stuck for too long activate hazard lights, honk their horns, and eventually despawn gracefully to clear the road.

### 👁️ Visuals & Synchronization
- **Turn Signals & Brake Lights**: Integrated with `custom_coronas` to provide realistic light effects for NPC vehicles.
- **Smooth Movement**: Utilizes `chemical_syncer_cr` for lag-free position and rotation synchronization across clients.
- **Ghost Mode Prevention**: Intelligent collision state management prevents physics explosions and stacking.

---

## 📦 Components

The system is modular and consists of several resources working together:

| Resource | Description |
| :--- | :--- |
| **`npchlc_traffic`** | **Core Generator**: Handles spawn logic, density control, and path reading. |
| **`npc_hlc`** | **AI Logic**: The "Brain" of the NPCs. Handles sensors, tasks, steering, and movement. |
| **`custom_coronas`** | **Visuals**: Shader-based system for rendering custom vehicle lights (indicators, brake lights). |
| **`server_coldata`** | **Data**: Provides server-side collision data for accurate ground detection. |

---

## ⚙️ Configuration

You can customize the core system behavior in `npchlc_traffic/generate.lua`:

### Scalability Settings
```lua
SCALABILITY_CONFIG = {
    CLUSTER_RADIUS = 150,           -- Radius to group players (meters)
    MIN_DENSITY_MODIFIER = 0.15,    -- Minimum traffic density when server is full
    PLAYERS_FOR_MIN_DENSITY = 500,  -- Player count at which density hits minimum
    SHARED_NPC_RADIUS = 200,        -- Radius for shared NPC visibility
}
```

### Traffic Density
```lua
-- Global spawn limits and density targets
local MAX_GLOBAL_NPCS = 2000      -- Absolute server safety limit
local SPAWN_RADIUS_ACTIVE = 8     -- Active spawn radius (chunks)
```

### Optimization Tweaks
In `npc_hlc/meta.xml`, you can toggle server-side collision checks:
```xml
<setting name="*server_colchecking" value="false" /> <!-- Set to false for better performance -->
```

---

## 🚀 Installation

1. **Download**: Clone or download the repository.
2. **Install**: Drop the `[sun_traffic]` folder (containing all sub-resources) into your MTA `server/mods/deathmatch/resources/` directory.
3. **ACL Config**: Ensure the resources have necessary permissions in `acl.xml`.
4. **Start**: Start the main resource group or each resource individually.
   ```bash
   start [environmental-project]
   ```
   *Note: Ensure `npc_hlc` and `server_coldata` start before `npchlc_traffic`.*

---

## ⚖️ License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)** License.

### You are free to:
- **Share** — copy and redistribute the material in any medium or format.
- **Adapt** — remix, transform, and build upon the material.

### Under the following terms:
- **Attribution** — You must give appropriate credit, provide a link to the license, and indicate if changes were made.
- **NonCommercial** — You may not use the material for commercial purposes.

> **⚠️ IMPORTANT:** You are **strictly prohibited** from selling this resource, including it in paid resource packs, or gating it behind a paywall. If you redistribute this code (modified or unmodified), you **MUST** credit the original authors and link back to this repository.

[View Full License Text](https://creativecommons.org/licenses/by-nc/4.0/)

---

## 🛠️ Credits

- **CrystalMV**: Original author of the `npc_hlc` library.
- **oBradom**: Implementation of Scalability, Speed Personality, Deadlock Resolution, and Modernization.
- **Ren712**: Author of the shader logic used in `custom_coronas`.

---
*Verified for MTA:SA 1.6+*
