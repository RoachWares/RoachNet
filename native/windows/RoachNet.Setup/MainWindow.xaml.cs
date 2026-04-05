using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace RoachNet.Setup;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "RoachNet Setup";
        Content = BuildContent();
    }

    private static UIElement BuildContent()
    {
        var root = new Grid
        {
            Background = MakeBrush(8, 10, 11)
        };

        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new StackPanel
        {
            Margin = new Thickness(36, 28, 36, 0)
        };

        header.Children.Add(Label("ROACHNET SETUP", 12, 180, FontWeights.SemiBold, MakeBrush(24, 245, 119)));
        header.Children.Add(TitleText("RoachNet for Windows beta.", 30));
        header.Children.Add(Body("This beta bundles the native setup shell and the main RoachNet shell for install and layout validation on Windows 11."));

        var stageStrip = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 16, 0, 0)
        };
        stageStrip.Children.Add(Badge("1 Welcome", true));
        stageStrip.Children.Add(Badge("2 Machine", false));
        stageStrip.Children.Add(Badge("3 Runtime", false));
        stageStrip.Children.Add(Badge("4 Launch", false));
        header.Children.Add(stageStrip);
        Grid.SetRow(header, 0);
        root.Children.Add(header);

        var bodyCard = new Border
        {
            Margin = new Thickness(36, 28, 36, 28),
            Padding = new Thickness(28),
            Background = MakeBrush(18, 22, 24),
            BorderBrush = MakeBrush(34, 40, 43),
            BorderThickness = new Thickness(1)
        };
        Grid.SetRow(bodyCard, 1);

        var bodyGrid = new Grid();
        bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var bodyStack = new StackPanel();
        bodyStack.Children.Add(Body("Everything lands inside the RoachNet folder so the beta stays self-contained and easy to reset."));
        bodyStack.Children.Add(FeatureBlock("INSTALL ROOT", "RoachNet\\"));
        bodyStack.Children.Add(FeatureBlock("RUNTIME", "Contained"));
        bodyStack.Children.Add(FeatureBlock("BETA SCOPE", "Native shell + setup"));
        bodyStack.Children.Add(FeatureBlock("NEXT", "Open the main app after setup"));
        bodyGrid.Children.Add(bodyStack);

        var emblem = new Border
        {
            Width = 160,
            Height = 160,
            Margin = new Thickness(24, 0, 0, 0),
            BorderBrush = MakeBrush(24, 245, 119),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        var emblemText = new TextBlock
        {
            Text = "RN",
            Foreground = MakeBrush(244, 247, 248),
            FontSize = 28,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        var emblemGrid = new Grid();
        emblemGrid.Children.Add(emblemText);
        emblem.Child = emblemGrid;
        Grid.SetColumn(emblem, 1);
        bodyGrid.Children.Add(emblem);

        bodyCard.Child = bodyGrid;
        root.Children.Add(bodyCard);

        var footer = new Grid
        {
            Margin = new Thickness(36, 0, 36, 28)
        };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        footer.Children.Add(new TextBlock
        {
            Text = "Windows beta only. Use it for setup and shell validation while the full Windows lane grows up.",
            Foreground = MakeBrush(147, 160, 165),
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap
        });

        var continueButton = new Button
        {
            Content = "Continue",
            Padding = new Thickness(18, 10, 18, 10),
            HorizontalAlignment = HorizontalAlignment.Right
        };
        Grid.SetColumn(continueButton, 1);
        footer.Children.Add(continueButton);

        Grid.SetRow(footer, 2);
        root.Children.Add(footer);

        return root;
    }

    private static TextBlock Label(string text, double fontSize, double letterSpacing, FontWeight weight, Brush foreground)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = fontSize,
            LetterSpacing = letterSpacing,
            FontWeight = weight,
            Foreground = foreground,
            Margin = new Thickness(0, 0, 0, 8)
        };
    }

    private static TextBlock TitleText(string text, double size)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = FontWeights.SemiBold,
            Foreground = MakeBrush(244, 247, 248),
            Margin = new Thickness(0, 0, 0, 12)
        };
    }

    private static TextBlock Body(string text)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = 15,
            Foreground = MakeBrush(147, 160, 165),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 14)
        };
    }

    private static Border FeatureBlock(string label, string value)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 11,
            Foreground = MakeBrush(147, 160, 165),
            Margin = new Thickness(0, 0, 0, 4)
        });
        stack.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            Foreground = MakeBrush(244, 247, 248),
            TextWrapping = TextWrapping.Wrap
        });

        return new Border
        {
            Child = stack,
            Background = MakeBrush(23, 28, 30),
            Margin = new Thickness(0, 0, 0, 12),
            Padding = new Thickness(16)
        };
    }

    private static Border Badge(string text, bool active)
    {
        return new Border
        {
            Background = active ? MakeBrush(26, 31, 33) : MakeBrush(20, 23, 25),
            BorderBrush = active ? MakeBrush(24, 245, 119) : MakeBrush(42, 47, 50),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 8, 12, 8),
            Margin = new Thickness(0, 0, 10, 0),
            Child = new TextBlock
            {
                Text = text,
                Foreground = active ? MakeBrush(244, 247, 248) : MakeBrush(147, 160, 165)
            }
        };
    }

    private static SolidColorBrush MakeBrush(byte r, byte g, byte b)
    {
        return new SolidColorBrush(ColorHelper.FromArgb(255, r, g, b));
    }
}
