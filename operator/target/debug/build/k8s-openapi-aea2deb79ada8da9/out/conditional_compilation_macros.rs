/// This macro evaluates to its contents if the `v1_31` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_31! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_31 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_31` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_31 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_31` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_31 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_32` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_32! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_32 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_32` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_32 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_32` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_32 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_33` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_33! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_33 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_33` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_33 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_33` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_33 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_34` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_34! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_34 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_34` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_34 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_34` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_34 { ($($tt:tt)*) => { }; }

/// This macro evaluates to its contents if the `v1_35` feature is enabled, otherwise it evaluates to nothing.
///
/// # Examples
///
/// ```rust
/// # #[macro_use] extern crate k8s_openapi;
/// k8s_if_1_35! {
///     use k8s_openapi::api::core::v1 as api;
/// }
/// ```
#[macro_export] macro_rules! k8s_if_1_35 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_35` or higher feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_ge_1_35 { ($($tt:tt)*) => { $($tt)* }; }

/// This macro evaluates to its contents if the `v1_35` or lower feature is enabled, otherwise it evaluates to nothing.
#[macro_export] macro_rules! k8s_if_le_1_35 { ($($tt:tt)*) => { $($tt)* }; }

/// A macro that emits a `match` expr with the given test expression and arms.
/// The match arms can be annotated with the other conditional compilation macros in this crate so that they're only emitted
/// if the predicate is true.
#[macro_export] macro_rules! k8s_match {
    (@inner { $test:expr } { $($arms:tt)* } { }) => {
        match $test { $($arms)* }
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_31!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_31!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_31!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_32!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_32!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_32!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_33!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_33!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_33!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_34!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_34!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_34!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_1_35!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_ge_1_35!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };
    (@inner { $test:expr } { $($arms:tt)* } { k8s_if_le_1_35!($($arm:tt)*), $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* } { $($arm)*, $($rest)* })
    };

    (@inner { $test:expr } { $($arms:tt)* } { $next_pat:pat $(if $cond:expr)? => $next_expr:expr, $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { $($arms)* $next_pat $(if $cond)? => $next_expr, } { $($rest)* })
    };

    ($test:expr, { $($rest:tt)* }) => {
        k8s_match!(@inner { $test } { } { $($rest)* })
    };
}
