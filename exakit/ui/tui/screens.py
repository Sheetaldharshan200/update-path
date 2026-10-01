"""The modal questions of the kit's screens: a single choice, a tick list, a yes/no, a line of text.

The keys match the console menus: Up/Down move, Space ticks, Enter continues, a digit picks,
``a``/``n`` take all or none, Esc backs out with the default.
"""

from __future__ import annotations

from collections.abc import Sequence

from rich.text import Text
from textual import events
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, OptionList, SelectionList
from textual.widgets.option_list import Option as ListOption
from textual.widgets.selection_list import Selection

from exakit.ui.widgets import Option


def _row(option: Option) -> Text:
    text = Text(option.label)
    if option.hint:
        text.append(f"  {option.hint}", style="dim")
    return text


class SelectScreen(ModalScreen[str | None]):
    """One choice out of a list; the answer is the option's id, None when backed out."""

    BINDINGS = [Binding("escape", "cancel", "Back")]

    def __init__(self, title: str, options: Sequence[Option], default: int) -> None:
        super().__init__()
        self.title_text = title
        self.options = list(options)
        self.default = default

    def compose(self) -> ComposeResult:
        """The title, the list, the key hint."""
        with Vertical(id="dialog"):
            yield Label(self.title_text, id="title")
            yield OptionList(*[ListOption(_row(o), id=o.id, disabled=o.disabled) for o in self.options], id="choices")
            yield Label("Up/Down move   Enter chooses   a digit picks   Esc backs out", id="hint")

    def on_mount(self) -> None:
        """Highlight the default."""
        choices = self.query_one(OptionList)
        if 1 <= self.default <= len(self.options):
            choices.highlighted = self.default - 1
        choices.focus()

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        """Enter on a row answers with it."""
        self.dismiss(event.option.id)

    def on_key(self, event: events.Key) -> None:
        """A digit picks that row."""
        if event.character and event.character.isdigit():
            index = int(event.character) - 1
            if 0 <= index < len(self.options) and not self.options[index].disabled:
                event.stop()
                self.dismiss(self.options[index].id)

    def action_cancel(self) -> None:
        """Esc: no answer."""
        self.dismiss(None)


class CheckboxScreen(ModalScreen[list[str]]):
    """Any number of choices; the answer is the ticked ids in the list's order."""

    BINDINGS = [Binding("enter", "done", "Continue", priority=True), Binding("escape", "cancel", "Back"),
                Binding("a", "all", "All", show=False), Binding("n", "none", "None", show=False)]

    def __init__(self, title: str, options: Sequence[Option], defaults: Sequence[str]) -> None:
        super().__init__()
        self.title_text = title
        self.options = list(options)
        self.defaults = [o.id for o in options if o.id in set(defaults) and not o.disabled]

    def compose(self) -> ComposeResult:
        """The title, the tick list, the key hint."""
        with Vertical(id="dialog"):
            yield Label(self.title_text, id="title")
            yield SelectionList[str](*[Selection(_row(o), o.id, o.id in self.defaults, disabled=o.disabled) for o in self.options], id="choices")
            yield Label("Up/Down move   Space ticks   Enter continues   a all   n none   Esc backs out", id="hint")

    def on_mount(self) -> None:
        """Focus the list."""
        self.query_one(SelectionList).focus()

    def action_done(self) -> None:
        """Enter: the ticked ids, in the list's order."""
        ticked = set(self.query_one(SelectionList).selected)
        self.dismiss([o.id for o in self.options if o.id in ticked])

    def action_all(self) -> None:
        """Tick everything that can be ticked."""
        self.query_one(SelectionList).select_all()

    def action_none(self) -> None:
        """Untick everything."""
        self.query_one(SelectionList).deselect_all()

    def action_cancel(self) -> None:
        """Esc: the defaults."""
        self.dismiss(list(self.defaults))


class ConfirmScreen(ModalScreen[bool]):
    """A yes/no question; Enter takes the default, y and n answer directly."""

    BINDINGS = [Binding("y", "yes", "Yes", show=False), Binding("n", "no", "No", show=False),
                Binding("enter", "default", "Default", priority=True), Binding("escape", "default", "Back")]

    def __init__(self, question: str, default: bool) -> None:
        super().__init__()
        self.question = question
        self.default = default

    def compose(self) -> ComposeResult:
        """The question and the two buttons."""
        with Vertical(id="dialog"):
            yield Label(self.question, id="title")
            with Horizontal(id="buttons"):
                yield Button("Yes", id="yes", variant="primary" if self.default else "default")
                yield Button("No", id="no", variant="primary" if not self.default else "default")
            yield Label(f"Enter takes {'yes' if self.default else 'no'}   y / n answer   Esc backs out", id="hint")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """A click answers."""
        self.dismiss(event.button.id == "yes")

    def action_yes(self) -> None:
        """y."""
        self.dismiss(True)

    def action_no(self) -> None:
        """n."""
        self.dismiss(False)

    def action_default(self) -> None:
        """Enter or Esc: the default."""
        self.dismiss(self.default)


class PromptScreen(ModalScreen[str]):
    """A line of text; an empty answer is the default."""

    BINDINGS = [Binding("escape", "cancel", "Back")]

    def __init__(self, question: str, default: str) -> None:
        super().__init__()
        self.question = question
        self.default = default

    def compose(self) -> ComposeResult:
        """The question and the field."""
        with Vertical(id="dialog"):
            yield Label(self.question, id="title")
            yield Input(value=self.default, id="answer")
            yield Label("Enter continues   Esc keeps the default", id="hint")

    def on_mount(self) -> None:
        """Focus the field."""
        self.query_one(Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Enter answers with the text, or the default when empty."""
        self.dismiss(event.value.strip() or self.default)

    def action_cancel(self) -> None:
        """Esc: the default."""
        self.dismiss(self.default)
