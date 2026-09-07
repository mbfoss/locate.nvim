if vim.fn.has("nvim-0.10") ~= 1 then
    error("locator.nvim requires Neovim >= 0.10")
end

if vim.g.loaded_locator then return end
vim.g.loaded_locator = true

-- Nothing under `lua/locator/` is required here: the command and the highlight
-- groups are all that has to exist before the first pick, so they are written
-- out rather than pulled in. `locator.apply_highlights()` states the same groups
-- for the `colorschemes` source, which re-applies them after a scheme switch.
vim.api.nvim_set_hl(0, "LocatorMatch", { default = true, link = "Visual" })
vim.api.nvim_set_hl(0, "LocatorPath", { default = true, link = "@module" })
vim.api.nvim_set_hl(0, "LocatorLspReference", { default = true, link = "Label" })
vim.api.nvim_set_hl(0, "LocatorBufferIndicator", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "LocatorFlagPill", { default = true, link = "Visual" })

vim.api.nvim_create_user_command("Locate", function(cmd_opts)
    require("locator.cmdline").run(cmd_opts)
end, {
    nargs    = "*",
    desc     = "Picker for files, grep etc...",
    complete = function(arg_lead, cmd_line, cursor_pos)
        return require("locator.cmdline").complete(arg_lead, cmd_line, cursor_pos)
    end,
})
