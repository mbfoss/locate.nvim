if vim.fn.has("nvim-0.11") ~= 1 then
    error("locate.nvim requires Neovim >= 0.11")
end

if vim.g.loaded_locate then return end
vim.g.loaded_locate = true

-- Nothing under `lua/locate/` is required here: the command and the highlight
-- groups are all that has to exist before the first pick, so they are written
-- out rather than pulled in. `locate.apply_highlights()` states the same groups
-- for the `colorschemes` source, which re-applies them after a scheme switch.
vim.api.nvim_set_hl(0, "LocateMatch", { default = true, link = "Visual" })
vim.api.nvim_set_hl(0, "LocatePath", { default = true, link = "@namespace" })
vim.api.nvim_set_hl(0, "LocateBufferIndicator", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "LocateFlagPill", { default = true, link = "Visual" })

vim.api.nvim_create_user_command("Locate", function(cmd_opts)
    require("locate.cmdline").run(cmd_opts)
end, {
    nargs    = "*",
    desc     = "Picker for files, grep etc...",
    complete = function(arg_lead, cmd_line, cursor_pos)
        return require("locate.cmdline").complete(arg_lead, cmd_line, cursor_pos)
    end,
})
