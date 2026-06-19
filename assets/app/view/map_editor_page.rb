# frozen_string_literal: true

require 'lib/hex'
require_relative '../game_class_loader'

module View
  # A minimal drag-and-drop editor for authoring the white/blue hexes of a
  # game's map. Draws its own SVG hex grid (reusing the engine's hex geometry so
  # positions line up with the real map) and emits a HEXES snippet for map.rb.
  #
  # Route: /map_editor/<game_title>  e.g. /map_editor/20seattle
  #
  # Editor state lives in the class-level STATE hash rather than in needs/ivars:
  # Snabberb recreates component instances on every render, and needs-backed
  # ivars are not reliably repopulated inside event handlers, so a plain
  # class-level hash is the robust place to keep mutable editor state.
  class MapEditorPage < Snabberb::Component
    include GameClassLoader

    needs :route

    ROUTE_FORMAT = %r{/map_editor/([^/?]*)/?}.freeze

    SIZE = 100
    LAYOUT = {
      flat: [SIZE * 3 / 2, SIZE * Math.sqrt(3) / 2],
      pointy: [SIZE * Math.sqrt(3) / 2, SIZE * 3 / 2],
    }.freeze
    MARGIN = 2     # extra rings of empty candidate hexes around the existing map
    SCALE = 0.42

    LETTERS = (('A'..'Z').to_a + ('AA'..'AZ').to_a).freeze

    TOOL_COLORS = { 'white' => :white, 'blue' => :blue }.freeze

    STATE = {
      paint: nil,      # { 'C4' => 'white', ... } or nil before seeding
      tool: 'white',   # 'white' | 'blue' | 'empty'
      dragging: false,
      output: nil,
      title: nil,        # game title the paint state was seeded from
      margin_x: MARGIN,  # empty candidate columns added left/right of the map
      margin_y: MARGIN,  # empty candidate rows added above/below the map
    }

    def render
      game_title = @route.match(ROUTE_FORMAT)[1]
      game = load_game_class(game_title)
      return h(:div, [h(:p, "Loading game: #{game_title}")]) unless game

      players = Array.new(game::PLAYER_RANGE.max) { |n| "Player #{n + 1}" }
      @game = game.new(players)

      seed!(game_title) if STATE[:paint].nil? || STATE[:title] != game_title

      h(:div, { on: { mouseup: ->(_e) { STATE[:dragging] = false } } }, [
          h(:h2, "Map Editor: #{game.full_title}"),
          render_toolbar,
          render_grid,
          render_output,
        ])
    end

    def render_toolbar
      tool_button = lambda do |tool, label|
        active = STATE[:tool] == tool
        props = {
          style: {
            margin: '0 6px 0 0',
            padding: '6px 12px',
            cursor: 'pointer',
            border: active ? '2px solid #4ea1ff' : '1px solid #888',
            borderRadius: '5px',
          },
          on: { click: ->(_e) { STATE[:tool] = tool; update } },
        }
        h(:button, props, label)
      end

      counts = (STATE[:paint] || {}).values
      status = "White: #{counts.count('white')}  Blue: #{counts.count('blue')}"

      step_button = lambda do |label, key, delta|
        h(:button, {
            style: { margin: '0 2px', padding: '6px 10px', cursor: 'pointer' },
            on: { click: ->(_e) { STATE[key] = [(STATE[key] || MARGIN) + delta, 1].max; update } },
          }, label)
      end
      axis_control = lambda do |name, key|
        [
          h(:span, { style: { marginLeft: '6px', marginRight: '4px' } }, name),
          step_button.call('−', key, -1),
          h(:span, { style: { margin: '0 2px' } }, (STATE[key] || MARGIN).to_s),
          step_button.call('+', key, 1),
        ]
      end

      h(:div, { style: { margin: '0.5rem 0' } }, [
          h(:span, { style: { marginRight: '8px' } }, 'Tool:'),
          tool_button.call('white', 'White'),
          tool_button.call('blue', 'Blue'),
          tool_button.call('empty', 'Erase'),
          h(:span, { style: { margin: '0 8px' } }, '|'),
          *axis_control.call('Cols ↔', :margin_x),
          *axis_control.call('Rows ↕', :margin_y),
          h(:span, { style: { margin: '0 8px' } }, '|'),
          h(:button, { style: { marginRight: '6px', padding: '6px 12px', cursor: 'pointer' },
                       on: { click: ->(_e) { generate_output } } }, 'Generate Ruby'),
          h(:button, { style: { marginRight: '6px', padding: '6px 12px', cursor: 'pointer' },
                       on: { click: ->(_e) { seed!(current_title); update } } }, 'Reload from game'),
          h(:span, { style: { marginLeft: '12px', fontWeight: 'bold' } }, status),
          h(:span, { style: { marginLeft: '12px', color: '#888' } },
            'Click or drag to paint. Drag with Erase to remove.'),
        ])
    end

    def render_grid
      cells = candidate_cells
      tx, ty = LAYOUT[@layout]
      width = (tx * ((@max_x - @min_x) + 2) + (SIZE * 2)) * SCALE
      height = (ty * ((@max_y - @min_y) + 2) + (SIZE * 2)) * SCALE

      nodes = cells.map { |coord, xy| hex_node(coord, xy[0], xy[1]) }

      h(:div, { style: { overflow: 'auto', border: '1px solid #444', margin: '0.5rem 0' } }, [
          h(:svg, { attrs: { width: width.round.to_s, height: height.round.to_s } }, [
              h(:g, { attrs: { transform: "scale(#{SCALE})" } }, nodes),
            ]),
        ])
    end

    def hex_node(coord, x, y)
      tx, ty = LAYOUT[@layout]
      px = (tx * (x - @min_x + 1)) + SIZE
      py = (ty * (y - @min_y + 1)) + SIZE
      color = (STATE[:paint] || {})[coord]
      fill =
        if (sym = TOOL_COLORS[color])
          Lib::Hex::COLOR[sym]
        else
          '#2b2b2b' # empty candidate hex
        end
      rot = @layout == :pointy ? ' rotate(30)' : ''

      props = {
        attrs: { transform: "translate(#{px}, #{py})#{rot}", fill: fill, stroke: 'black',
                 'stroke-width': 1, cursor: 'pointer' },
        on: {
          click: ->(_e) { paint(coord) },
          mousedown: ->(_e) { start_paint(coord) },
          mouseover: ->(_e) { drag_paint(coord) },
        },
      }

      h(:g, props, [
          h(:polygon, attrs: { points: Lib::Hex::POINTS }),
          h(:text, { attrs: { 'text-anchor': 'middle', y: 10, 'font-size': 30,
                              fill: color ? '#0009' : '#888', 'pointer-events': 'none' } }, coord),
        ])
    end

    def render_output
      output = STATE[:output]
      return h(:div) unless output

      h(:div, { style: { margin: '0.5rem 0' } }, [
          h(:p, 'Paste into the game\'s map.rb (HEXES):'),
          h(:textarea, {
              attrs: { readonly: true, spellcheck: false },
              style: { width: '100%', height: '260px', fontFamily: 'monospace', fontSize: '12px' },
            }, output),
        ])
    end

    # --- painting ---------------------------------------------------------

    def start_paint(coord)
      STATE[:dragging] = true
      paint(coord)
    end

    def drag_paint(coord)
      paint(coord) if STATE[:dragging]
    end

    def paint(coord)
      STATE[:paint] = {} if STATE[:paint].nil?
      if STATE[:tool] == 'empty'
        STATE[:paint].delete(coord)
      else
        STATE[:paint][coord] = STATE[:tool]
      end
      update
    end

    # --- state / geometry -------------------------------------------------

    def current_title
      @route.match(ROUTE_FORMAT)[1]
    end

    def seed!(title)
      paint = {}
      @game.hexes.each do |hex|
        next if hex.empty

        case hex.tile&.color
        when :white then paint[hex.id] = 'white'
        when :blue then paint[hex.id] = 'blue'
        end
      end
      STATE[:paint] = paint
      STATE[:title] = title
      STATE[:output] = nil
    end

    # all coords to draw: existing painted hexes + a parity-matching grid of
    # empty candidate positions around them
    def candidate_cells
      @layout = @game.layout == :pointy ? :pointy : :flat

      painted = (STATE[:paint] || {}).keys.map { |c| [c, parse_coord(c)] }
      xs = painted.map { |pair| pair[1][0] }
      ys = painted.map { |pair| pair[1][1] }
      xs = [0] if xs.empty?
      ys = [0] if ys.empty?

      mx = STATE[:margin_x] || MARGIN
      my = STATE[:margin_y] || MARGIN
      @min_x = [xs.min - mx, 0].max
      @max_x = xs.max + mx
      @min_y = [ys.min - my, 0].max
      @max_y = ys.max + my

      parity = (xs.first + ys.first).even?

      cells = {}
      painted.each { |coord, xy| cells[coord] = xy }
      (@min_x..@max_x).each do |x|
        (@min_y..@max_y).each do |y|
          next unless (x + y).even? == parity

          coord = LETTERS[x] + (y + 1).to_s
          cells[coord] ||= [x, y]
        end
      end
      cells
    end

    def parse_coord(coord)
      m = coord.match(/([A-Z]+)(-?\d+)/)
      return [0, 0] unless m

      [LETTERS.index(m[1]) || 0, m[2].to_i - 1]
    end

    # --- output -----------------------------------------------------------

    def generate_output
      by_color = { 'white' => [], 'blue' => [] }
      (STATE[:paint] || {}).each { |coord, color| by_color[color] << coord if by_color[color] }

      blocks = %w[white blue].map { |color| format_group(color, by_color[color]) }
      STATE[:output] = blocks.join("\n")
      update
    end

    def format_group(color, coords)
      sorted = coords.sort_by { |c| parse_coord(c) }
      if sorted.empty?
        "#{color}: {\n          },"
      else
        rows = sorted.each_slice(10).map { |slice| '            ' + slice.join(' ') }
        "#{color}: {\n          %w[\n#{rows.join("\n")}\n] => '',\n          },"
      end
    end
  end
end
