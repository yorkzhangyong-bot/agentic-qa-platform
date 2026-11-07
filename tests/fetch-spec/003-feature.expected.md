# Feature Specification: Coupon codes at checkout

> Source: Spec Kit folder specs/003-feature/ (spec.md, plan.md, data-model.md, contracts/coupons-api.yaml, contracts/events.md, quickstart.md, tasks.md)

## spec.md

# Feature Specification: Coupon codes at checkout

**Feature Branch**: `003-feature`
**Status**: Draft

## User Scenarios & Testing

### User Story 1 - Apply a coupon (Priority: P1)

A shopper enters a coupon code on the checkout page and sees the discounted total.

## Requirements

### Functional Requirements

- **FR-001**: Shoppers MUST be able to enter a coupon code on the checkout page.
- **FR-002**: A valid code MUST reduce the order total by its discount.
- **FR-003**: An expired code MUST show "Coupon expired" and leave the total unchanged.

## Success Criteria

- **SC-001**: A shopper can apply a valid coupon in under 10 seconds.


## plan.md

# Implementation Plan: Coupon codes at checkout

**Branch**: `003-feature` | **Spec**: [spec.md](spec.md)

## Summary

Add a coupon field to the checkout page, validated by `POST /api/coupons/apply`.


## data-model.md

# Data Model: Coupon codes at checkout

## Coupon

| Field | Type | Notes |
|---|---|---|
| code | string | Unique, upper case |
| discount_percent | integer | 1–100 |
| expires_at | timestamp | Expired codes are rejected |


## contracts/coupons-api.yaml

```yaml
# Coupon API contract
openapi: 3.0.3
info:
  title: Coupons
  version: 1.0.0
paths:
  /api/coupons/apply:
    post:
      summary: Apply a coupon to the current cart
      responses:
        "200":
          description: Coupon applied
        "410":
          description: Coupon expired

```

## contracts/events.md

# Events

- `coupon.applied`: emitted when a valid coupon changes the order total.


## quickstart.md

# Quickstart: Coupon codes at checkout

1. Start the app with `npm start`.
2. Add any item to the cart and open `/checkout`.
3. Enter `SAVE10` and click **Apply**.


## tasks.md

# Tasks: Coupon codes at checkout

- [ ] T001 Add the coupon field to the checkout page (FR-001)
- [ ] T002 Apply valid coupons to the order total (FR-002)
- [ ] T003 Reject expired coupons with "Coupon expired" (FR-003)

