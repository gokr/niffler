import { mount } from "svelte";
import App from "./App.svelte";
import "./app.css";
import { initTheme } from "./lib/theme";

initTheme();

const target = document.getElementById("app")!;
mount(App, { target });
