# [E2E] Sign Up flow issues found during browser E2E testing

## Summary

During E2E browser testing of the Sign Up flow on `claw.snese.net`, several issues were identified.

## Test Environment
- URL: `https://claw.snese.net`
- Test account: `e2etest@snese.net`
- Auto-confirm: enabled via Pre Sign-up Lambda `AUTO_CONFIRM=true`
- User Pool: `us-west-2_yRqDzKF0t`
- Date: 2026-03-31

## Issues Found

### 1. 🔴 `logo.svg` returns 404 (favicon broken)

The `<link rel="icon" href="logo.svg">` in `auth-ui/index.html` references `/logo.svg`, but this file is not deployed to the S3/CloudFront origin. The file exists in the `auth-ui/` directory locally but was not uploaded during deployment.

**Evidence:** `curl -sI https://claw.snese.net/logo.svg` returns HTTP 404. Console shows two 404 errors for `logo.svg`.

**Expected:** Favicon should load correctly.

### 2. 🔴 Sign Up tab `aria-selected` state incorrect

When switching from Sign In to Sign Up tab, the `aria-selected="true"` attribute remains on the Sign In tab instead of moving to the Sign Up tab. The button text and form fields update correctly (showing "Create Account", password hint, ToS), but the tab accessibility state is wrong.

**Evidence:** Browser snapshot shows `tab "Sign In" [selected]` even after clicking Sign Up tab.

**Expected:** `aria-selected` should toggle correctly between tabs.

### 3. 🔴 WebSocket URL uses stale localStorage value after Sign Up

After a successful Sign Up, the Gateway Dashboard pre-fills the WebSocket URL field with a value from localStorage belonging to a **previous** user/tenant (e.g., `wss://claw.snese.net/t/e2efinal` instead of `wss://claw.snese.net/t/e2etest`).

**Evidence:** After signing up as `e2etest@snese.net`, the WebSocket URL field showed `wss://claw.snese.net/t/e2efinal` (from a previous session).

**Expected:** The WebSocket URL should be auto-populated based on the current authenticated user's tenant, not from stale localStorage.

### 4. 🔴 Gateway token mismatch on Connect after Sign Up

After correcting the WebSocket URL to the proper tenant path and clicking Connect, the connection fails with: `unauthorized: gateway token mismatch (open the dashboard URL and paste the token in Control UI settings)`.

This suggests the gateway token from the JWT (set by Post-confirmation Lambda) does not match the token stored in the K8s Secret for the tenant pod.

**Evidence:** Error message displayed in the Gateway Dashboard status area.

**Expected:** After Sign Up with auto-confirm, the gateway token in the JWT should match the K8s Secret, and Connect should succeed.

### 5. 🟡 Local repo pre-signup Lambda code out of sync with deployed code

The deployed Pre Sign-up Lambda includes `AUTO_CONFIRM` logic (reading `AUTO_CONFIRM` env var and setting `autoConfirmUser`/`autoVerifyEmail` on the event response), but the local repo code in `cdk/lambda/pre-signup/index.py` does not contain this logic.

**Expected:** Local repo should be kept in sync with deployed code.

## Steps to Reproduce

1. Navigate to `https://claw.snese.net`
2. Switch to Sign Up tab
3. Enter email (`e2etest@snese.net`) and password (`E2eTest2026Pass`)
4. Click "Create Account"
5. Wait for workspace provisioning to complete
6. Observe the Gateway Dashboard
7. Correct WebSocket URL if needed and click Connect
8. Observe token mismatch error

## Screenshots

Screenshots were captured during testing (e2e-01 through e2e-07) documenting each step of the flow.
