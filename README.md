# ESP32 Autonomous Navigation Robot

A 4WD autonomous mobile robot that receives a destination from a mobile application over Wi-Fi, plans a route on a user-defined grid using the A* pathfinding algorithm, and detects obstacles with an ultrasonic sensor. When an obstacle blocks the current route, the robot stops, scans nearby directions, updates its obstacle map, and attempts to replan.

> **Project status:** Prototype. Motion timing and turning values require calibration for the specific chassis, battery level, floor surface, and motor characteristics.

## Project Overview

The system consists of:
- An ESP32-based robot controller.
- A 4WD chassis driven through an L298N motor driver.
- A front-facing ultrasonic distance sensor.
- A Wi-Fi access point hosted by the ESP32.
- A Flutter mobile application for selecting the start position, destination, and blocked grid cells.

The robot uses grid-based navigation. The mobile application supplies mission information, while the ESP32 performs path planning and controls the motors.

## Robot

![Assembled 4WD autonomous navigation robot](images/robot.jpg)

## Main Features

- Wi-Fi access point hosted by the ESP32.
- TCP communication between the mobile application and robot.
- User-defined grid dimensions and cell size.
- A* path planning with 4-directional or 8-directional movement configured in firmware.
- Diagonal movement with diagonal path cost.
- Ultrasonic distance measurement using the median of three readings.
- Obstacle detection while moving.
- Local obstacle marking and route replanning.
- Stop command and stop-on-client-disconnect behavior.

## Hardware

The current prototype and firmware indicate the following hardware:

| Component | Purpose |
|---|---|
| ESP32 development board | Main controller and Wi-Fi communication |
| 4WD robot chassis with DC geared motors | Robot movement |
| L298N motor driver | Motor direction and speed control |
| Ultrasonic distance sensor | Forward obstacle detection |
| Battery pack | Robot power supply |
| Jumper wires | Electrical connections |

Check the actual wiring before powering the robot. The pin assignments below are taken from the current firmware and should be verified against the assembled hardware.

## Firmware Pin Configuration

| ESP32 GPIO | Firmware signal |
|---|---|
| GPIO 18 | IN1 |
| GPIO 19 | IN2 |
| GPIO 21 | IN3 |
| GPIO 22 | IN4 |
| GPIO 25 | ENA (PWM) |
| GPIO 26 | ENB (PWM) |
| GPIO 5 | Ultrasonic TRIG |
| GPIO 23 | Ultrasonic ECHO |

**Electrical note:** Ensure the ultrasonic ECHO output voltage is safe for the ESP32 GPIO (3.3 V maximum). Use an appropriate voltage divider or level shifter if required. Connect the grounds of the ESP32 and motor driver together. Do not power the motors directly from the ESP32.

## Wi-Fi and Communication

The firmware configures the ESP32 as a Wi-Fi access point.

| Setting | Current firmware value |
|---|---|
| SSID | `ROBOT_NET` |
| Password | `robot1234` (prototype default; change before public deployment) |
| TCP port | `8266` |

The mobile application connects to the ESP32 network and communicates using newline-terminated text commands.

### Commands received by the ESP32

| Command | Purpose |
|---|---|
| `CONFIG,width,height,cellCm` | Set grid width, height, and cell size |
| `STARTPOS,x,y` | Set the robot's starting grid coordinate |
| `DEST,x,y` | Set the destination coordinate |
| `OBS,x,y` | Mark a grid cell as blocked |
| `RMOBS,x,y` | Remove a blocked cell |
| `CLEAROBS` | Clear the obstacle map |
| `START` | Plan a route and begin navigation |
| `STOP` | Stop the current mission and motors |
| `RESET` | Stop, clear obstacles, and clear the destination |

The firmware can send status and telemetry messages such as `STATUS`, `POS`, and `OBSTACLE` to the connected client.

## Navigation and Obstacle Handling

1. The app sends the grid configuration, starting coordinate, destination, and user-marked obstacles.
2. On `START`, the ESP32 runs A* to find a route through unblocked cells.
3. The robot turns toward the next grid cell and moves for a calibrated duration.
4. During forward movement, the ultrasonic sensor checks the distance ahead.
5. If repeated readings are within the configured obstacle threshold, the robot stops and reverses for the elapsed movement duration.
6. The detected cell is marked as blocked. The robot scans nearby directions and adds detected neighboring obstacles to its map.
7. A* is run again to find an alternate route. If no route is available, the firmware reports an error.

### A* pathfinding

The firmware supports:
- 8-directional movement when `NDIR` is set to `8`.
- 4-directional movement when `NDIR` is set to `4`.
- Straight movement cost of `1`.
- Diagonal movement cost of approximately `1.4142`.
- An octile-distance heuristic for 8-directional movement and Manhattan distance for 4-directional movement.

## Firmware Configuration

Open `firmware/robot_controller/robot_controller.ino` in Arduino IDE and check these calibration settings before testing:

| Setting | Current default | Meaning |
|---|---:|---|
| `DRIVE_SPEED` | 150 | Forward/reverse PWM speed |
| `TURN_SPEED` | 170 | Turning PWM speed |
| `OBSTACLE_DISTANCE` | 25 cm | Obstacle threshold |
| `OBSTACLE_HITS` | 3 | Consecutive close readings before stopping |
| `MS_PER_CM` | 45 | Timed movement calibration |
| `TURN_90_MS` | 600 ms | Approximate 90-degree turn duration |
| `NDIR` | 8 | Number of allowed movement directions |
| `GW`, `GH` | 12 × 12 | Initial grid dimensions |
| `cellCm` | 25 cm | Initial grid cell size |

These are prototype values, not guaranteed measurements. Calibrate in a clear test area at low speed. Timed motor movement is open-loop: without wheel encoders or another localization sensor, actual travel distance and heading can drift.

## Getting Started

1. Install the Arduino IDE.
2. Install the ESP32 board support package.
3. Open `firmware/robot_controller/robot_controller.ino`.
4. Select the correct ESP32 board and serial port.
5. Verify the pin wiring and motor power arrangement.
6. Upload the firmware.
7. Open Serial Monitor at `115200` baud and confirm the Wi-Fi access point starts.
8. Connect the mobile device to `ROBOT_NET`.
9. Run the companion Flutter app and connect to the robot's TCP endpoint using the network details configured in the app.
10. Test `STOP` first, then test short movements in a clear area before attempting a complete navigation mission.

The Flutter application source is not included in this initial repository snapshot. Add it under `mobile_app/` when ready.

## Repository Structure

```text
.
├── README.md
├── firmware/
│   └── robot_controller/
│       └── robot_controller.ino
├── hardware/
├── docs/
├── images/
│   └── robot.jpg
└── mobile_app/
```

## Current Limitations

- Motion distance and turning angle are based on time calibration.
- The robot does not currently use wheel encoder feedback for precise odometry.
- The ultrasonic sensor provides local distance measurements; this is not a full SLAM mapping system.
- Obstacle scanning is limited to the directions and distance thresholds implemented in the firmware.
- Performance depends on floor surface, battery voltage, motor mismatch, and sensor placement.

## Future Improvements

- Add wheel encoders and closed-loop motion control.
- Improve heading estimation with an IMU.
- Add more robust localization and map updates.
- Improve obstacle sensing and multi-directional scanning.
- Document the companion Flutter application and its communication protocol.
- Add demonstration videos and detailed circuit diagrams.

## Safety

Raise the robot or keep its wheels clear of the floor during initial motor-direction tests. Keep hands, cables, and loose objects away from moving wheels. Use a physical power switch or accessible battery disconnect during testing.

## License

No license has been selected yet. Until a license is added, the repository's contents are not automatically granted an open-source reuse license.
