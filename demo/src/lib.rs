pub fn current_pid() -> u32 {
    rustix::process::getpid().as_raw_nonzero().get() as u32
}
