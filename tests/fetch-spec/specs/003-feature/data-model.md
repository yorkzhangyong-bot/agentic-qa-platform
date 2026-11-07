# Data Model: Coupon codes at checkout

## Coupon

| Field | Type | Notes |
|---|---|---|
| code | string | Unique, upper case |
| discount_percent | integer | 1–100 |
| expires_at | timestamp | Expired codes are rejected |
