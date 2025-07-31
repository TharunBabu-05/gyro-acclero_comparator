# Bus Fraud Detection Demo Instructions

## How to Test the Fraud Detection System

### Setup:
1. **Bus Device**: Your gyro_compare_fixed app (this device)
2. **Passenger Device**: Smart Ticket MTC app (friend's phone)

### Demo Flow:

#### Step 1: Passenger Buys Ticket
- Friend opens Smart Ticket MTC app
- Buys ticket from "Stop 0" to "Stop 6" 
- System generates unique session ID (e.g. "ABC123DEF")
- Session ID automatically sent to your Firebase

#### Step 2: Your Bus App Detects Passenger
- Your app automatically shows: "🚌 New passenger detected!"
- Shows session ID and planned exit stop
- Starts monitoring sensor data

#### Step 3: Passenger Boards Bus
- Friend starts sensor tracking in their app
- Both apps compare gyroscope/accelerometer data
- Your app shows "✅ Passenger Connected"

#### Step 4: Fraud Detection
- Use the "+" button to simulate bus stops (0→1→2→3...)
- When bus reaches Stop 6: Passenger should exit
- If bus continues to Stop 7, 8, 9... without passenger exiting: **FRAUD DETECTED!**
- Penalty calculated: Extra stops × ₹5

### Key Features:

**Real-time Monitoring:**
- Correlation Score: Shows how similar the motion patterns are
- Green indicators: Passenger is on bus
- Red indicators: Passenger not detected on bus

**Fraud Detection:**
- Automatic detection when passenger exceeds planned stops
- Penalty calculation (₹5 per extra stop)
- Alert notifications

**Bus Stop Simulation:**
- Use the "+" button in app bar to advance bus stops
- Watch fraud detection trigger when passenger overstays

### Expected Results:

**Legitimate Journey:**
- Passenger boards at Stop 0
- High correlation score (>0.7)
- Passenger exits at Stop 6
- No penalty

**Fraud Scenario:**
- Passenger boards at Stop 0  
- High correlation initially
- Bus reaches Stop 6, 7, 8... passenger still on bus
- **🚨 FRAUD DETECTED!**
- Penalty: (8-6) × ₹5 = ₹10

### Firebase Data Structure:

```json
{
  "passenger_sessions": {
    "ABC123DEF": {
      "passenger_id": "user_123",
      "planned_exit_stop": 6,
      "status": "active"
    }
  },
  "fraud_detection": {
    "ABC123DEF": {
      "fraud_detected": true,
      "extra_stops": 2,
      "penalty_amount": 10,
      "correlation_score": 0.85
    }
  }
}
```

This system prevents revenue loss by accurately detecting passengers who violate their ticket terms!
